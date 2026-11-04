// Offline metadata-only replay against the actual production AudioBurstGuard.
// It does not decode media, implement FEC, control the iPad, or shape traffic.
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <limits.h>
#include "AudioBurstRecovery.h"

int AppVersionQuad[4] = {7,1,450,0};
int AudioPacketDuration = 5;
CONNECTION_LISTENER_CALLBACKS ListenerCallbacks = {0};
static uint64_t simulatedTime;
uint64_t PltGetMicroseconds(void) { return simulatedTime; }

typedef struct {
    int have_high;
    int64_t high, minimum;
    uint64_t start, changes, positive_us;
} AdaptiveClock;

static int64_t extend_sequence(int64_t high, uint16_t seq) {
    return high + (int16_t)(seq-(uint16_t)high);
}

// Experimental comparator ONLY. Track first-seen advancing media, including
// currently late packets. One-second lower envelopes reject isolated copies.
// Positive phase changes may move future deadlines by at most 100ms/window;
// negative clock corrections retain the production 1ms/window limit.
static void consider_clock(AdaptiveClock* clock,AUDIO_BURST_GUARD* guard,
                           uint16_t seq,uint64_t when) {
    int64_t extended=clock->have_high?extend_sequence(clock->high,seq):seq;
    if(clock->have_high && extended<=clock->high)return;
    clock->high=extended;clock->have_high=1;
    if(!guard->anchored)return;
    int64_t nominal=(int64_t)guard->anchorLocalUs+
                    (int16_t)(seq-guard->anchorSeq)*(int64_t)AudioPacketDuration*1000;
    int64_t error=(int64_t)when-nominal;
    if(!clock->start){clock->start=when;clock->minimum=error;return;}
    if(error<clock->minimum)clock->minimum=error;
    if(when-clock->start>=1000000){
        int64_t correction=clock->minimum;
        if(correction>100000)correction=100000;
        if(correction< -1000)correction= -1000;
        if(correction>500 || correction< -500){
            if((int64_t)guard->anchorLocalUs+correction>=0){
                guard->anchorLocalUs=(uint64_t)((int64_t)guard->anchorLocalUs+correction);
                guard->nextExpectedDeadlineUs=(uint64_t)((int64_t)guard->nextExpectedDeadlineUs+correction);
                clock->changes++;
                if(correction>0)clock->positive_us+=(uint64_t)correction;
            }
        }
        clock->start=when;clock->minimum=INT64_MAX;
    }
}


typedef struct {
    uint64_t emitted,ready,duplicate_delivery,max_gap,last_emit;
    uint64_t underrun_us,pcm_end,pcm_drops;
    unsigned startup;
    int64_t high;
    uint32_t delivered[65536];
} Metrics;

static void drain(AUDIO_BURST_GUARD* guard,Metrics* metrics,uint64_t until) {
    unsigned work=0;
    while(guard->anchored && AudioBurstGuardGetNextDeadlineUs(guard)<=until){
        if(++work>1000000){fprintf(stderr,"unbounded replay gap\n");exit(8);}
        uint64_t when=AudioBurstGuardGetNextDeadlineUs(guard);
        simulatedTime=when;
        uint16_t size=0,seq=0;BURST_FRAME_STATUS status=BURST_FRAME_EMPTY;
        uint8_t* payload=AudioBurstGuardFinalizeNext(guard,when,&size,&seq,&status);
        free(payload);metrics->emitted++;
        if(metrics->last_emit && when-metrics->last_emit>metrics->max_gap)
            metrics->max_gap=when-metrics->last_emit;
        metrics->last_emit=when;
        if(metrics->startup<4){
            if(++metrics->startup==4)metrics->pcm_end=when+20000;
        }else{
            if(when>metrics->pcm_end){metrics->underrun_us+=when-metrics->pcm_end;metrics->pcm_end=when;}
            if(metrics->pcm_end-when>250000)metrics->pcm_drops++;else metrics->pcm_end+=5000;
        }
        if(status!=BURST_FRAME_PLC){
            int64_t extended=metrics->high<0?seq:extend_sequence(metrics->high,seq);
            if(extended>metrics->high)metrics->high=extended;
            if(metrics->delivered[seq]==(uint32_t)extended)metrics->duplicate_delivery++;
            metrics->delivered[seq]=(uint32_t)extended;metrics->ready++;
        }
    }
}

int main(int argc,char**argv){
    if(argc!=4){fprintf(stderr,"usage: replay events.txt baseline|adaptive recovery-ms\n");return 2;}
    FILE* input=fopen(argv[1],"r");if(!input)return 3;
    int adaptive=strcmp(argv[2],"adaptive")==0;
    if(!adaptive && strcmp(argv[2],"baseline")!=0)return 4;
    unsigned delay=(unsigned)strtoul(argv[3],NULL,10);
    if(delay<20 || delay>1000)return 5;
    AUDIO_BURST_GUARD guard;AudioBurstGuardInit(&guard,delay,20);
    AdaptiveClock clock={0};Metrics metrics={.high= -1};
    memset(metrics.delivered,0xff,sizeof(metrics.delivered));
    unsigned long long when;
    unsigned seq,stamp;char kind;
    uint64_t requests=0,first_us=0,last_us=0;
    while(fscanf(input," %c %llu %u %u",&kind,&when,&seq,&stamp)==4){
        if(seq>65535 || when<last_us){fclose(input);return 6;}
        last_us=when;if(!first_us)first_us=when;
        // Recompute decoder wakeups from each policy's own deadlines. Reusing
        // recorded wakeups would wrongly starve a counterfactual decoder.
        drain(&guard,&metrics,when);simulatedTime=when;
        if(kind=='R'){
            if(adaptive)consider_clock(&clock,&guard,(uint16_t)seq,when);
            uint8_t bytes[sizeof(RTP_PACKET)+32]={0};PRTP_PACKET packet=(PRTP_PACKET)bytes;
            packet->header=0x80;packet->packetType=97;packet->sequenceNumber=(uint16_t)seq;
            packet->timestamp=stamp;packet->ssrc=1;
            uint64_t old_resync=guard.countTimelineResyncs;
            AudioBurstGuardIngest(&guard,bytes,sizeof(bytes),when);
            if(guard.countTimelineResyncs!=old_resync){clock.start=0;clock.minimum=INT64_MAX;}
        }else if(kind=='P')requests++;
        else{fclose(input);return 7;}
    }
    fclose(input);
    printf("{\"mode\":\"%s\",\"worker\":\"ideal independently scheduled; no FEC or codec\","
           "\"window_ms\":%u,\"duration_seconds\":%.6f,"
           "\"recorded_decoder_requests\":%llu,\"emitted_frames\":%llu,\"media_frames\":%llu,"
           "\"plc_frames\":%llu,\"late_discarded_copies\":%llu,\"resyncs\":%llu,"
           "\"duplicate_media_deliveries\":%llu,\"max_output_gap_us\":%llu,"
           "\"virtual_pcm_underrun_us\":%llu,\"virtual_pcm_drops\":%llu,"
           "\"phase_corrections\":%llu,\"positive_phase_correction_us\":%llu}\n",
           adaptive?"adaptive":"baseline",delay,(last_us-first_us)/1e6,
           (unsigned long long)requests,(unsigned long long)metrics.emitted,(unsigned long long)metrics.ready,
           (unsigned long long)guard.countPlcSynthesized,(unsigned long long)guard.countLateDiscarded,
           (unsigned long long)guard.countTimelineResyncs,(unsigned long long)metrics.duplicate_delivery,
           (unsigned long long)metrics.max_gap,(unsigned long long)metrics.underrun_us,
           (unsigned long long)metrics.pcm_drops,(unsigned long long)clock.changes,(unsigned long long)clock.positive_us);
    AudioBurstGuardCleanup(&guard);return 0;
}
