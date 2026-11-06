#!/usr/bin/env python3
"""Validate one captured Panfrost compute submit and emit a static client payload.

The host shim never executes the shader. Only the physical replay may establish
its result. Reject changed VAs, missing buffers, job cycles and input sentinels.
"""
import argparse
import hashlib
import json
import struct
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('capture', type=Path)
parser.add_argument('header', type=Path)
args = parser.parse_args()
root = args.capture.resolve()
events = [json.loads(line) for line in (root / 'events.jsonl').read_text().splitlines()]
submits = [event for event in events if event['op'] == 'submit']
assert len(submits) == 1, 'Only a single compute submission is supported'
submit = submits[0]
assert submit['requirements'] == 0, 'Expected compute, not fragment submission'
live, prelude, params = {}, [], {}
for event in events:
    op = event['op']
    if op == 'submit':
        break
    if op == 'param':
        params[event['param']] = event['value']
    elif op == 'alloc':
        ident = event['id']
        assert 1 <= ident < 128 and ident not in live
        assert 0 < event['size'] <= 256 * 1024**2 and event['size'] % 16384 == 0
        assert 0x2000000 <= event['va'] < event['va'] + event['size'] <= 0x100000000
        assert event['flags'] & ~3 == 0
        live[ident] = event
        prelude.append(event)
    elif op == 'free':
        assert event['id'] in live
        del live[event['id']]
        prelude.append(event)
    else:
        raise AssertionError(f'Unexpected pre-submit event: {event}')

snapshots = {}
for event in events:
    if event['op'] != 'snapshot':
        continue
    assert event['seq'] == submit['seq']
    ident = event['id']
    assert ident in live and ident not in snapshots
    path = (root / event['file']).resolve()
    assert path.parent == root
    data = path.read_bytes()
    assert len(data) == live[ident]['size']
    snapshots[ident] = data
assert 0 < len(snapshots) <= 64 and sum(map(len, snapshots.values())) <= 256 * 1024**2

def read_va(address, length):
    matches = [(ident, address - live[ident]['va']) for ident in snapshots
               if live[ident]['va'] <= address and address + length <= live[ident]['va'] + len(snapshots[ident])]
    assert len(matches) == 1, f'Job address outside captured buffers: {address:#x}'
    ident, offset = matches[0]
    return snapshots[ident][offset:offset+length]

job_types, visited, cursor = [], set(), submit['jc']
while cursor:
    assert cursor not in visited and len(visited) < 64, 'Cyclic or excessive job chain'
    visited.add(cursor)
    header = read_va(cursor, 32)
    assert header[16] & 1, 'Expected 64-bit descriptor'
    kind = (header[16] >> 1) & 127
    assert kind in (1, 2, 3, 4), f'Unexpected job type {kind}'
    job_types.append(kind)
    cursor = struct.unpack_from('<Q', header, 24)[0]
assert 4 in job_types, 'Capture must contain a compute shader job'

def locate(pattern):
    found = []
    for ident, data in snapshots.items():
        offset = data.find(pattern)
        if offset >= 0:
            assert data.find(pattern, offset + 1) < 0
            found.append((ident, offset))
    assert len(found) == 1, 'Input/output marker must occur exactly once'
    return found[0]

input_id, input_offset = locate(struct.pack('<II', 17, 0x4e49504c))
output_id, output_offset = locate(struct.pack('<II', 0xa5a5a5a5, 0x54554f50))
assert input_id != output_id and output_offset + 4096 <= len(snapshots[output_id])
assert snapshots[output_id][output_offset+8:output_offset+4096] == b'\xa5' * 4088

lines = ['/* Generated from real Panfrost submission inputs. No host GPU result. */']
spans = []
for ident, data in snapshots.items():
    at = 0
    while at < len(data):
        if not any(data[at:at+256]):
            at += 256
            continue
        start = at
        at += 256
        while at < len(data) and at - start < 4096 and any(data[at:at+256]):
            at += 256
        blob = data[start:at]
        name = f'replay_bytes_{len(spans)}'
        lines.append(f'static const unsigned char {name}[] = {{' + ','.join(map(str, blob)) + '};')
        spans.append((ident, start, len(blob), name))
lines.append('static const struct replay_event replay_events[] = {')
for event in prelude:
    if event['op'] == 'alloc':
        lines.append('{1,%(id)d,%(size)d,%(flags)d,%(va)dULL},' % event)
    else:
        lines.append('{2,%(id)d,0,0,0},' % event)
lines.append('};\nstatic const struct replay_param replay_params[] = {')
lines.extend(f'{{{param},{value}ULL}},' for param, value in sorted(params.items()))
lines.append('};\nstatic const struct replay_span replay_spans[] = {')
lines.extend(f'{{{ident},{offset},{size},{name}}},' for ident, offset, size, name in spans)
lines.append('};\nstatic const unsigned replay_submit_ids[] = {' + ','.join(map(str, snapshots)) + '};')
lines.extend([f'#define REPLAY_JC {submit["jc"]}ULL',
              f'#define REPLAY_INPUT_ID {input_id}', f'#define REPLAY_INPUT_OFFSET {input_offset}',
              f'#define REPLAY_OUTPUT_ID {output_id}', f'#define REPLAY_OUTPUT_OFFSET {output_offset}'])
args.header.parent.mkdir(parents=True, exist_ok=True)
args.header.write_text('\n'.join(lines) + '\n')
manifest = {'job_types': job_types, 'jc': submit['jc'], 'parameters': params,
            'input': [input_id, input_offset], 'output': [output_id, output_offset],
            'expected': 58, 'initial': 0xa5a5a5a5, 'buffer_count': len(snapshots),
            'buffer_bytes': sum(map(len, snapshots.values())), 'span_count': len(spans),
            'snapshot_sha256': {str(i): hashlib.sha256(data).hexdigest() for i,data in snapshots.items()},
            'header_sha256': hashlib.sha256(args.header.read_bytes()).hexdigest(),
            'gpu_execution_verified': False}
args.header.with_suffix('.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(json.dumps(manifest, indent=2))
