#!/usr/bin/env python3
"""Bounded passive summaries of existing trace files. Never controls an app/network."""
import argparse
from collections import Counter
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import time
import urllib.error
import urllib.request
from diagnose import load_audio, receiver_metrics


def atomic_json(path,value):
    path=Path(path)
    temporary=path.with_suffix(path.suffix+'.partial')
    temporary.write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n')
    temporary.chmod(0o600)
    temporary.replace(path)


def newest_upload(directory):
    newest=0
    for path in Path(directory).glob('*.mtrace.gz'):
        try:
            newest=max(newest,path.stat().st_mtime)
        except FileNotFoundError:
            pass
    return newest


def summarize(directory,now):
    events,quality=load_audio(directory,last_batches=150,max_events=300000)
    received,playout,receiver=receiver_metrics(events)
    receiver.pop('plc_examples',None)
    manifest_path=Path(directory)/'manifest.json'
    try:
        manifest=json.loads(manifest_path.read_text())
    except FileNotFoundError:
        manifest={}
    counts=Counter(e[6] for e in events)
    outputs=[e for e in events if e[6]==6]
    video=[e for e in events if e[6]==11]
    newest=newest_upload(directory)
    fresh=now-newest<60
    latest_output=outputs[-1] if outputs else None
    markers=[e for e in events if e[6]==7]
    ended=bool(markers and markers[-1][1]==0)
    stall=bool(fresh and not ended and len(video)>=100 and
               ((latest_output and video[-1][0]-latest_output[0]>5000000) or
                (not latest_output and events and video[-1][0]-events[0][0]>5000000)))
    tail_start=(events[-1][0]-10000000) if events else 0
    tail_playout=[e for e in events if e[6]==3 and e[0]>=tail_start]
    tail_receive=sum(e[6]==1 and e[8]&127==97 and e[0]>=tail_start for e in events)
    plc_rate=(sum(e[1]==4 for e in tail_playout)/len(tail_playout)) if tail_playout else 0
    stuck_plc=bool(fresh and not ended and len(tail_playout)>=1000 and tail_receive>=500 and plc_rate>=.95)
    path_events=[dict(time_us=e[0],interface=e[1],status=e[2],flags=e[8]) for e in events if e[6]==12]
    return dict(observed_at=datetime.fromtimestamp(now,timezone.utc).isoformat(),
                session=Path(directory).name,capture=quality,receiver=receiver,
                stream_configuration={k:manifest[k] for k in ('width','height','fps','bitrate_kbps','audio_playout_delay_ms','app_version') if k in manifest},
                initial_path=manifest.get('path'),network_path_events=path_events[-10:],
                spool_dropped_batches_cumulative=max((e[2] for e in events if e[6]==13 and e[1]==2),default=0),
                trace_age_seconds=max(0,now-newest),fresh_upload=fresh,
                window_start_us=events[0][0] if events else None,
                window_end_us=events[-1][0] if events else None,
                video_frames=counts[11],audio_output_samples=counts[6],
                latest_output=dict(time_us=latest_output[0],queued_bytes=latest_output[1],
                                   repairs=latest_output[2],status=latest_output[8]) if latest_output else None,
                session_end_observed=ended,
                audio_output_progress_stall=stall,
                sustained_plc_while_media_arrives=stuck_plc,
                last_ten_seconds=dict(playout_frames=len(tail_playout),received_audio_copies=tail_receive,plc_fraction=plc_rate),
                caveat='Receiver-only window: missing receive records and clipped boundaries are uncertain. PLC is not network loss; no inference about audible host silence.')


def send_email(configuration,subject,body):
    key=Path(configuration['email_key_file']).expanduser().read_text().strip()
    payload=json.dumps({'from':'Codex <onboarding@resend.dev>',
                        'to':[configuration['email_to']],'subject':subject,'text':body}).encode()
    request=urllib.request.Request('https://api.resend.com/emails',data=payload,
                                  headers={'Authorization':'Bearer '+key,'Content-Type':'application/json',
                                           'User-Agent':'MoonlightDiagnostics/1.0'})
    with urllib.request.urlopen(request,timeout=20) as response:
        response.read(4096)
        return response.status


def main(configuration,notify_start=False):
    now=time.time()
    root=Path(configuration['root']).expanduser()
    output=Path(configuration['output']).expanduser()
    output.mkdir(parents=True,exist_ok=True,mode=0o700)
    atomic_json(output/'host-clock.json',dict(wall_time=now,host_monotonic_us=int(time.monotonic()*1e6)))
    state_path=output/'state.json'
    state=json.loads(state_path.read_text()) if state_path.exists() else {'sessions':{}}
    notification_errors=[]

    def notify(subject,body):
        if not configuration.get('email_to'):
            return False
        try:
            send_email(configuration,subject,body)
            return True
        except Exception as error:
            notification_errors.append(dict(type=type(error).__name__,http_status=getattr(error,'code',None)))
            return False

    if notify_start and not state.get('startup_notified'):
        state['startup_notified']=notify('Moonlight 被动诊断已启动',
            '逐包日志接收继续运行。每五分钟生成有界摘要，仅分析已有日志；不制造丢包、不重连、不改网络或客户端参数。\n'
            '出现可观察的音频输出停滞会通知；普通监控摘要每天最多一次，不发送媒体、输入、凭据或完整日志。')
        state['last_daily_notification']=now
    directories=sorted((d for d in root.iterdir() if d.is_dir()),
                       key=lambda d:d.stat().st_mtime,reverse=True)[:2]
    reports=[]
    for directory in directories:
        files=sorted(directory.glob('*.mtrace.gz'))
        if not files:
            continue
        previous=state['sessions'].get(directory.name,{})
        batch=int(files[-1].name.split('.')[0])
        if previous.get('last_batch')==batch:
            continue
        report=summarize(directory,now)
        reports.append(report)
        atomic_json(output/(directory.name+'.json'),report)
        issue=report['audio_output_progress_stall'] or report['sustained_plc_while_media_arrives']
        if issue and not previous.get('alert_active'):
            notified=notify('Moonlight 观察到音频管线异常迹象',
                '新记录满足以下至少一项：视频继续但音频输出记录落后超过五秒；或真实音频包仍在到达，而十秒播放样本几乎全为 PLC。\n'
                '这是需要检查的管线异常迹象，不等同于已确认听感失声或已证明的网络丢包。诊断器不会自动重连或修改参数。\n'
                '本地摘要已保留在 Moonlight 诊断状态目录。')
            previous['alert_active']=notified
        elif not issue and previous.get('alert_active') and report['fresh_upload']:
            if notify('Moonlight 音频输出记录恢复推进','后续被动记录中音频输出与视频均继续推进；未执行自动干预。'):
                previous['alert_active']=False
        previous.update(last_batch=batch,updated_at=now)
        state['sessions'][directory.name]=previous
    state['sessions']={k:v for k,v in state['sessions'].items() if now-v.get('updated_at',0)<7*86400}
    if reports:
        latest=dict(observed_at=datetime.fromtimestamp(now,timezone.utc).isoformat(),sessions=reports,
                    intervention='none; metadata files only')
        atomic_json(output/'latest.json',latest)
        date=datetime.fromtimestamp(now,timezone.utc).strftime('%Y-%m-%d')
        with (output/(date+'.jsonl')).open('a') as history:
            history.write(json.dumps(latest,ensure_ascii=False,separators=(',',':'))+'\n')
        if now-state.get('last_daily_notification',now)>=86400:
            summary='\n'.join(f"会话 {r['session'][:8]}：播放帧 {r['receiver']['observed_playout_frames']}，"
                              f"PLC {r['receiver']['playout_status'].get(4,0)}，"
                              f"日志批次缺口 {r['capture']['missing_batch_count']}。"
                              for r in reports)
            if notify('Moonlight 被动诊断每日摘要',summary+'\nPLC 不能直接视为网络丢包率；未执行自动干预。'):
                state['last_daily_notification']=now
    # Only our generated summaries expire; original trace retention belongs to the receiver.
    for path in output.glob('*.jsonl'):
        if now-path.stat().st_mtime>7*86400:
            path.unlink()
    state['last_run_at']=now
    state['notification_errors']=notification_errors
    atomic_json(state_path,state)
    newest=max((newest_upload(d) for d in directories),default=0)
    atomic_json(output/'health.json',dict(observed_at=datetime.fromtimestamp(now,timezone.utc).isoformat(),
                latest_upload_age_seconds=max(0,now-newest) if newest else None,
                new_session_summaries=len(reports),
                note='No new uploads alone cannot distinguish app suspension, an ended stream, and network loss.'))
    print(json.dumps(dict(updated_sessions=len(reports),notification_errors=notification_errors)))


def notify_failure(configuration):
    output=Path(configuration['output']).expanduser()
    output.mkdir(parents=True,exist_ok=True,mode=0o700)
    path=output/'failure-notification.json'
    old=json.loads(path.read_text()) if path.exists() else {}
    if time.time()-old.get('sent_at',0)<3600:
        return
    try:
        send_email(configuration,'Moonlight 被动诊断后台任务异常退出',
                   '只读摘要或主机发送元数据保留任务异常退出。Sunshine 和 iPad 未被诊断器重启或改参。\n'
                   '请检查 moonlight-diagnostics-watch.service 与 moonlight-diagnostics-host.service 的用户级日志。')
        atomic_json(path,dict(sent_at=time.time()))
        print('failure_notification_sent')
    except Exception as error:
        print(json.dumps(dict(notification_error=type(error).__name__,http_status=getattr(error,'code',None))))


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config',type=Path,required=True)
    parser.add_argument('--notify-start',action='store_true')
    parser.add_argument('--notify-failure',action='store_true')
    args=parser.parse_args()
    os.umask(0o077)
    configuration=json.loads(args.config.read_text())
    if args.notify_failure:
        notify_failure(configuration)
    else:
        main(configuration,args.notify_start)
