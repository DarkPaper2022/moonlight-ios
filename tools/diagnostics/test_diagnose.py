import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from diagnose import Sequence, receiver_metrics, join_sender, arrival_patterns


def event(t,seq,kind,value=0,flags=97):
    return (t,value,0,0,seq,120,kind,1,flags,0)


class PairedDiagnosisTests(unittest.TestCase):
    def test_rollover_and_reanchor_do_not_invent_a_new_epoch(self):
        sequence=Sequence()
        self.assertEqual([sequence.extend(n) for n in (65534,0,65535,1,0,2)],
                         [65534,65536,65535,65537,65536,65538])

    def test_received_late_and_not_observed_are_distinct(self):
        rows=[event(100,10,1),event(110,10,2,flags=0x161),event(150,10,3,value=1),
              event(200,11,3,value=4),event(210,12,3,value=4),event(300,11,1)]
        received,playout,report=receiver_metrics(rows)
        self.assertEqual(report['plc_classification'],
                         {'first_received_after_playout':1,'no_receive_record':1})
        self.assertEqual(report['plc_first_arrival_lateness_us']['p50'],100)

    def test_sender_pause_is_separate_from_receive_jitter_budget(self):
        times=[1000000,1005000,2010000,2015000]
        segment=dict(first_us=times[0],packets={i:(t,100) for i,t in enumerate(times)})
        received={i:[(t-times[0]+20000,100)] for i,t in enumerate(times)}
        report=join_sender(segment,received)
        budget=next(b for b in report['counterfactual_deadline_budgets'] if b['window_ms']==300)
        self.assertEqual(budget['late_against_sender_pacing_reference'],0)
        self.assertEqual(budget['late_against_fixed_5ms_rtp_reference'],2)
        self.assertEqual(report['relative_receive_delay_us']['maximum'],0)

    def test_phase_correlation_does_not_relabel_copy_identity(self):
        rows=[(i,i*5000,i*5000+(120000 if i%80<16 else 0),1) for i in range(800)]
        report=arrival_patterns(rows,0,0)
        self.assertEqual(report['outcomes']['delayed_first_one_copy'],160)
        lag=next(r for r in report['exploratory_autocorrelation'] if r['lag_ms']==400)
        self.assertAlmostEqual(lag['correlation'],1.0)


class OfflineReplayTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary=tempfile.TemporaryDirectory()
        cls.binary=Path(cls.temporary.name)/'replay'
        build=subprocess.run(['sh',str(Path(__file__).with_name('build_replay.sh')),str(cls.binary)],
                             capture_output=True,text=True)
        if build.returncode:
            raise RuntimeError(build.stderr)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def test_both_policies_preserve_a_regular_stream(self):
        path=Path(self.temporary.name)/'events.txt'
        rows=[f'R {1000000+i*5000} {i} {i*5}' for i in range(1000)]
        rows.append('P 6295000 999 1')
        path.write_text('\n'.join(rows)+'\n')
        for mode in ('baseline','adaptive'):
            run=subprocess.run([str(self.binary),str(path),mode,'300'],capture_output=True,text=True)
            self.assertEqual(run.returncode,0)
            report=json.loads(run.stdout.splitlines()[-1])
            self.assertEqual(report['media_frames'],1000)
            self.assertEqual(report['plc_frames'],0)
            self.assertEqual(report['duplicate_media_deliveries'],0)
            self.assertEqual(report['virtual_pcm_underrun_us'],0)

    def test_replay_refuses_time_reversal(self):
        path=Path(self.temporary.name)/'bad.txt'
        path.write_text('R 1000000 0 0\nR 900000 1 5\n')
        run=subprocess.run([str(self.binary),str(path),'baseline','300'],capture_output=True)
        self.assertNotEqual(run.returncode,0)


if __name__=='__main__':
    unittest.main()
