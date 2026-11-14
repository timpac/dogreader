"""Bounded recovery sweep for an existing operations runner. Dry run by default."""
import argparse
import json
from pathlib import Path
import re


def sweep(workflow, *, limit=100, after='', enqueue=False, emit=print):
    scanned = 0
    last = ''
    failed = 0
    # start_offset is inclusive. One extra listing entry allows skipping the cursor.
    for blob in workflow.bucket.list_blobs(prefix='jobs/',
            start_offset=f'jobs/{after}.json' if after else 'jobs/', max_results=limit + 1):
        match = re.fullmatch(r'jobs/([0-9a-f]{32})\.json', blob.name)
        if not match or match[1] <= after:
            continue
        if scanned >= limit:
            break
        job_id = match[1]
        scanned += 1
        last = job_id
        try:
            state, _ = workflow.read(f'state/{job_id}.json')
            state = state or workflow.initial_state(job_id)
            if enqueue:
                if workflow.completed(job_id):
                    status = 'ready'
                else:
                    status = workflow.dispatch(job_id)['status']
            else:
                status = state['status']
            emit(json.dumps(dict(event='recovery_scan', job_id=job_id, status=status, dry_run=not enqueue)))
        except Exception as exc:
            failed += 1
            emit(json.dumps(dict(event='recovery_error', job_id=job_id, error_type=type(exc).__name__)))
    # A complete final page resets the cursor; revisit the full keyspace next time.
    return dict(scanned=scanned, failed=failed, next_cursor=last if scanned == limit else '')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--enqueue', action='store_true', help='Repair dispatches; this can initiate paid TTS')
    parser.add_argument('--limit', type=int, default=100)
    parser.add_argument('--after', default='')
    parser.add_argument('--cursor-file', type=Path, help='Persist progress across scheduled, bounded sweeps')
    args = parser.parse_args()
    if not 1 <= args.limit <= 1000:
        parser.error('--limit must be between 1 and 1000')
    after = args.after
    if args.cursor_file and args.cursor_file.exists():
        after = args.cursor_file.read_text().strip()
    if after and not re.fullmatch('[0-9a-f]{32}', after):
        parser.error('Invalid cursor')
    from main import engine
    summary = sweep(engine(), limit=args.limit, after=after, enqueue=args.enqueue)
    print(json.dumps(dict(event='recovery_summary', **summary)))
    if args.cursor_file:
        args.cursor_file.write_text(summary['next_cursor'])
    return 1 if summary['failed'] else 0


if __name__ == '__main__':
    raise SystemExit(main())
