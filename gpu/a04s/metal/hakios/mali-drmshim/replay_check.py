#!/usr/bin/env python3
"""Exercise replay rejection gates with actual captured buffer data."""
import json
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

source = Path(sys.argv[1]).resolve()
generator = Path(__file__).with_name('make_replay.py')
with tempfile.TemporaryDirectory(prefix='mali-replay-check-', dir=source) as directory:
    root = Path(directory)
    assert root.resolve().parent == source, 'Temporary cleanup must stay in the supplied capture directory'
    for case in ('valid', 'cycle', 'missing_job', 'prefilled_answer', 'invalid_va', 'duplicate_id'):
        target = root / case
        target.mkdir()
        shutil.copyfile(source / 'events.jsonl', target / 'events.jsonl')
        for path in source.glob('submit-*-bo-*.bin'):
            shutil.copyfile(path, target / path.name)
        events = [json.loads(line) for line in (target / 'events.jsonl').read_text().splitlines()]
        submission = next(event for event in events if event['op'] == 'submit')
        allocations = {event['id']: event for event in events if event['op'] == 'alloc'}
        job = next(event for event in events if event['op'] == 'snapshot' and
                   allocations[event['id']]['va'] <= submission['jc'] <
                   allocations[event['id']]['va'] + allocations[event['id']]['size'])
        if case == 'cycle':
            path = target / job['file']
            data = bytearray(path.read_bytes())
            struct.pack_into('<Q', data, submission['jc'] - allocations[job['id']]['va'] + 24, submission['jc'])
            path.write_bytes(data)
        elif case == 'missing_job':
            events.remove(job)
        elif case == 'prefilled_answer':
            pattern = struct.pack('<II', 0xa5a5a5a5, 0x54554f50)
            for path in target.glob('submit-*-bo-*.bin'):
                data = path.read_bytes()
                if pattern in data:
                    path.write_bytes(data.replace(pattern, struct.pack('<II', 58, 0x54554f50)))
        elif case == 'invalid_va':
            next(event for event in events if event['op'] == 'alloc')['va'] = 0
        elif case == 'duplicate_id':
            at = next(i for i,event in enumerate(events) if event['op'] == 'alloc')
            events.insert(at, dict(events[at]))
        (target / 'events.jsonl').write_text(''.join(json.dumps(event)+'\n' for event in events))
        result = subprocess.run([sys.executable, str(generator), str(target), str(target/'payload.h')],
                                capture_output=True, text=True)
        assert (result.returncode == 0) == (case == 'valid'), (case, result.stdout, result.stderr)
        print(f'{case}: {"accepted" if case == "valid" else "rejected"}')
