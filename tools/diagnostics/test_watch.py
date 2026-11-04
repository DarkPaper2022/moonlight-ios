import gzip
import json
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch
from protocol import HEADER,EVENT
from watch import summarize,main,send_email,notify_failure


class PassiveWatchTests(unittest.TestCase):
    def fixture(self,root,ended=False):
        directory=root/'session';directory.mkdir()
        rows=[EVENT.pack(0,0,0,0,0,0,6,1,1,0)]
        rows.extend(EVENT.pack(i*60000,0,0,0,0,0,11,2,0,0) for i in range(1,110))
        if ended:rows.append(EVENT.pack(6600000,0,0,0,0,0,7,3,0,0))
        data=gzip.compress(HEADER.pack(b'MLTRACE1',1,32,len(rows),0,0)+b''.join(rows))
        (directory/'0000000000.mtrace.gz').write_bytes(data)
        return directory,data

    def test_stall_signal_and_explicit_session_end_are_distinct(self):
        for ended in (False,True):
            with tempfile.TemporaryDirectory() as tmp:
                directory,data=self.fixture(Path(tmp),ended)
                report=summarize(directory,time.time())
                self.assertEqual(report['audio_output_progress_stall'],not ended)
                self.assertEqual(report['session_end_observed'],ended)
                self.assertEqual((directory/'0000000000.mtrace.gz').read_bytes(),data)

    def test_no_new_batches_do_not_repeat_reports(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)/'traces';root.mkdir();directory,data=self.fixture(root,True)
            output=Path(tmp)/'state'
            config=dict(root=str(root),output=str(output))
            main(config)
            original=(output/'latest.json').read_bytes()
            main(config)
            self.assertEqual((output/'latest.json').read_bytes(),original)
            self.assertEqual((directory/'0000000000.mtrace.gz').read_bytes(),data)


class NotificationTests(unittest.TestCase):
    def test_notification_uses_an_identifiable_user_agent(self):
        with tempfile.TemporaryDirectory() as tmp:
            key=Path(tmp)/'key';key.write_text('test-key')
            with patch('watch.urllib.request.urlopen') as open_url:
                open_url.return_value.__enter__.return_value.status=200
                self.assertEqual(send_email(dict(email_key_file=str(key),email_to='test@example.com'),'status','metadata'),200)
                request=open_url.call_args.args[0]
                self.assertEqual(request.get_header('User-agent'),'MoonlightDiagnostics/1.0')

    def test_failure_notifications_do_not_repeat_same_incident(self):
        with tempfile.TemporaryDirectory() as tmp:
            config=dict(output=tmp)
            with patch('watch.send_email',return_value=200) as send:
                notify_failure(config);notify_failure(config)
                self.assertEqual(send.call_count,1)

    def test_continuous_plc_with_arriving_media_is_reported(self):
        for media_arriving in (True,False):
            with tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp);rows=[]
                for i in range(2200):
                    t=i*5000
                    rows.append(EVENT.pack(t,4,0,0,i,0,3,1,0,0))
                    if media_arriving:rows.append(EVENT.pack(t,0,0,0,i,100,1,1,97,0))
                    if i%200==0:rows.append(EVENT.pack(t,1920,0,0,0,0,6,1,1,0))
                data=gzip.compress(HEADER.pack(b'MLTRACE1',1,32,len(rows),0,0)+b''.join(rows))
                (root/'0000000000.mtrace.gz').write_bytes(data)
                report=summarize(root,time.time())
                self.assertEqual(report['sustained_plc_while_media_arrives'],media_arriving)
                self.assertFalse(report['audio_output_progress_stall'])
