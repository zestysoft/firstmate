#!/usr/bin/env python3
"""Build a record-only landing tree; never change refs, index or checkout.

Usage: fm-local-record-replay.py PROJECT TASK HEAD LINE CONFIG [--contained|--validate-records]
CONFIG is the optional home configuration file; docs/configuration.md's
"Local landing records" section owns its schema and defaults. Missing paths
have nothing to preserve. Malformed configuration or present records refuse.
A handover entry must be a single append-only suffix containing the exact task
id (bounded by non-id characters), without identifying another indexed task.
Paragraphs and headings are unrestricted. Earlier bytes are immutable. Task indexes
are objects keyed by record name, plain arrays of task objects, or legacy
wrappers with exactly one task array. Keyed records identify this task by a
non-empty string `task`; metadata and historical records without that field
are opaque. Other records may share a task name, but this task must match at
most one record. Arrays use `task` when present, otherwise legacy `id`, and
require unique names. Neither record keys nor positions identify this task.
Only this task's entry may change; other entries and wrapper fields must
match the base. The line's bytes are retained, including other objects' spelling.
Conflicting versions of this task's own entry refuse rather than guessing.
Non-record changes must merge into LINE without contributing content, with
unchanged modes on task-changed paths. --validate-records checks normal fast-forwards for existing record loss while
allowing new approved records. --contained proves the resulting tree
is already LINE, for cleanup; it never authorizes rewriting worker content.
Requires Python 3 and git merge-tree --write-tree (Git 2.38+).
"""
import collections
import json
import os
from pathlib import PurePosixPath
import re
import subprocess
import sys
import tempfile


class Refusal(Exception):
    pass


def refuse(message):
    raise Refusal(message)


def git(*args, data=None, env=None, check=True):
    result = subprocess.run(['git', '-C', project, *args], input=data,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    if check and result.returncode:
        refuse('Git proof unavailable: ' + result.stderr.decode(errors='replace').strip())
    return result


def tree(ref):
    rows = git('ls-tree', '-r', '-z', ref).stdout.split(b'\0')
    return {os.fsdecode(path): tuple(meta.decode().split())
            for row in rows if row for meta, path in [row.split(b'\t', 1)]}


def blob(ref, path):
    item = trees[ref].get(path)
    if item is None:
        return b''
    if item[0] != '100644' or item[1] != 'blob':
        refuse(f'{path}: shared record must be a regular non-executable file')
    return git('cat-file', 'blob', item[2]).stdout


def loads(raw):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                refuse('duplicate JSON key ' + repr(key))
            result[key] = value
        return result
    return json.loads(raw, object_pairs_hook=pairs,
                      parse_constant=lambda value: refuse('invalid JSON number ' + value))


def lost(path, old, new):
    missing = collections.Counter(old.splitlines()) - collections.Counter(new.splitlines())
    if missing:
        lines = [repr(line.decode(errors='replace')) for line in missing]
        refuse(f'{path}: would lose line(s): ' + ', '.join(lines))
    refuse(f'{path}: changes bytes outside this task entry')


def handover(path, base, head, line, other_tasks=()):
    for raw in (base, head, line):
        raw.decode('utf-8')
        if b'\0' in raw or re.search(rb'(?m)^(<<<<<<< |=======\r?$|>>>>>>> )', raw):
            refuse(f'{path}: unparseable handover record')
    if not head.startswith(base):
        lost(path, base, head)
    entry = head[len(base):]
    if not entry:
        return line
    if base and not base.endswith(b'\n'):
        refuse(f'{path}: base does not end at an append boundary')
    token = re.compile(rb'(?<![A-Za-z0-9_-])' + re.escape(task.encode()) + rb'(?![A-Za-z0-9_-])')
    if not token.search(entry):
        refuse(f'{path}: appended entry does not identify task {task}')
    for identity in other_tasks:
        foreign = re.compile(rb'(?<![A-Za-z0-9_-])' + re.escape(identity.encode()) + rb'(?![A-Za-z0-9_-])')
        if foreign.search(entry):
            refuse(f'{path}: appended suffix also identifies task {identity!r}; own entry is ambiguous')
    if token.search(base):
        refuse(f'{path}: task {task} already has a base entry; append identity is ambiguous')
    if not line.startswith(base):
        lost(path, base, line)
    if token.search(line):
        if line.count(entry) == 1:
            return line
        refuse(f'{path}: conflicting or ambiguous entry for task {task}')
    if line and not line.endswith(b'\n'):
        refuse(f'{path}: line does not end at an append boundary')
    return line + entry


def index(raw, path):
    if not raw:
        refuse(f'{path}: missing task index on one side')
    text = raw.decode('utf-8')
    try:
        obj = loads(text)
    except (Refusal, ValueError) as error:
        refuse(f'{path}: malformed task index: {error}')
    if isinstance(obj, list):
        shape = ('array', None)
        tasks = obj
    elif isinstance(obj, dict):
        if (all(isinstance(value, dict) for value in obj.values()) or
                any(isinstance(value, dict) and 'task' in value for value in obj.values())):
            shape = ('object', None)
            tasks = [value for value in obj.values()
                     if isinstance(value, dict) and 'task' in value]
        else:
            arrays = [key for key, value in obj.items() if isinstance(value, list)]
            if len(arrays) != 1:
                refuse(f'{path}: task index record values must be objects, or a wrapper must have exactly one task array')
            shape = ('wrapped', arrays[0])
            tasks = obj[arrays[0]]
    else:
        refuse(f'{path}: task index must be a JSON object or array')

    def identity(value):
        if not isinstance(value, dict):
            refuse(f'{path}: task entry must be an object')
        field = 'task' if shape[0] == 'object' or 'task' in value else 'id'
        name = value.get(field)
        if not isinstance(name, str) or not name.strip():
            refuse(f'{path}: every task entry needs a non-empty string {field}')
        return name

    names = [identity(value) for value in tasks]
    if names.count(task) > 1 or (shape[0] != 'object' and len(set(names)) != len(names)):
        refuse(f'{path}: duplicate task name or id')
    # Walk original tokens, retaining the key and colon too for keyed records.
    # Splicing only the own span preserves all other line bytes verbatim.
    decoder = json.JSONDecoder()

    def entries(pos, keyed):
        pos += 1  # opening brace or bracket
        while True:
            while text[pos].isspace() or text[pos] == ',':
                pos += 1
            if text[pos] == ('}' if keyed else ']'):
                return
            start = pos
            name = None
            if keyed:
                name, pos = decoder.raw_decode(text, pos)
                while text[pos].isspace() or text[pos] == ':':
                    pos += 1
            value_start = pos
            value, pos = decoder.raw_decode(text, pos)
            yield name, value, start, pos, value_start

    opening = len(text) - len(text.lstrip())
    if shape[0] == 'wrapped':
        opening = next(value_start for name, _, _, _, value_start in entries(opening, True)
                       if name == shape[1])
    spans = {}
    closing = opening + 1
    own = None
    for name, value, start, end, _ in entries(opening, shape[0] == 'object'):
        key = name if shape[0] == 'object' else identity(value)
        spans[key] = (start, end, text[start:end])
        is_own = (isinstance(value, dict) and value.get('task') == task
                  if shape[0] == 'object' else key == task)
        if is_own:
            if own is not None:
                refuse(f'{path}: duplicate task name {task!r}; own entry is ambiguous')
            own = key
        closing = end
    while text[closing].isspace():
        closing += 1
    return obj, shape, spans, closing, text, own, names


def task_index(path, base, head, line):
    if not base and not head:
        index(line, path)
        return line
    b, h, l = [index(raw, path) for raw in (base, head, line)]
    if b[1] != h[1] or b[1] != l[1]:
        refuse(f'{path}: task index shape or task array name changed')
    kind, key = b[1]
    if base == head:
        return line
    if h[5] is None:
        refuse(f'{path}: branch has no entry for task {task}')
    for identity, span in b[2].items():
        if identity == b[5]:
            continue
        if identity not in h[2]:
            refuse(f'{path}: would lose task entry {identity!r}: {span[2]}')
        if h[2][identity][2] != span[2]:
            refuse(f'{path}: branch changes another task entry {identity!r}: {span[2]}')
    for identity in h[2]:
        if identity != h[5] and identity not in b[2]:
            refuse(f'{path}: branch adds another task entry {identity!r}')
    if kind == 'wrapped' and ({k: v for k, v in b[0].items() if k != key} !=
                              {k: v for k, v in h[0].items() if k != key}):
        refuse(f'{path}: branch changes fields outside the task array')
    own = h[2][h[5]][2]
    if l[5] is not None:
        start, end, current = l[2][l[5]]
        if current == own:
            return line
        if b[5] is None or current != b[2][b[5]][2]:
            refuse(f'{path}: conflicting entry for task {task}')
        result = l[4][:start] + own + l[4][end:]
    else:
        pos = l[3]
        result = l[4][:pos] + (',' if l[2] else '') + '\n' + own + '\n' + l[4][pos:]
    parsed = index(result.encode(), path)
    for identity, span in l[2].items():
        if identity != l[5] and parsed[2].get(identity, (None, None, None))[2] != span[2]:
            refuse(f'{path}: would lose task entry {identity!r}: {span[2]}')
    return result.encode()


def validate_preservation(path, kind, head_raw, line_raw):
    if kind == 'handover':
        handover(path, b'', b'', head_raw)
        handover(path, b'', b'', line_raw)
        if not head_raw.startswith(line_raw):
            lost(path, line_raw, head_raw)
        return
    h = index(head_raw, path) if path in trees[head] else None
    l = index(line_raw, path) if path in trees[line] else None
    if l:
        if h and h[1] != l[1]:
            refuse(f'{path}: task index shape or task array name changed')
        for identity, span in l[2].items():
            if identity != l[5] and (not h or h[2].get(identity, (None, None, None))[2] != span[2]):
                refuse(f'{path}: would lose or rewrite task entry {identity!r}: {span[2]}')
        if not h:
            refuse(f'{path}: would remove the task index')


def write_tree(ref, replacements):
    with tempfile.TemporaryDirectory(prefix='fm-record-replay-') as tmp:
        env = dict(os.environ, GIT_INDEX_FILE=tmp + '/index')
        git('read-tree', ref, env=env)
        for path, item in replacements.items():
            if item is None:
                git('update-index', '--force-remove', '--', path, env=env)
            else:
                mode, kind, oid = item
                if kind != 'blob':
                    refuse(f'{path}: cannot substitute a non-blob record')
                git('update-index', '--add', '--cacheinfo', mode, oid, path, env=env)
        return git('write-tree', env=env).stdout.strip().decode()


def run():
    config = [{'path': 'HANDOFF.md', 'kind': 'handover'},
              {'path': 'orchestrator/tasks.json', 'kind': 'task-index'}]
    if os.path.lexists(config_path):
        with open(config_path, 'rb') as stream:
            config = loads(stream.read())
    if not isinstance(config, list):
        refuse('local-landing-records.json must be an array')
    records = {}
    for item in config:
        if not isinstance(item, dict) or set(item) != {'path', 'kind'}:
            refuse('record configuration needs path and kind')
        path, kind = item['path'], item['kind']
        if (not isinstance(path, str) or not path or path.startswith('/') or
                any(p in ('', '.', '..') for p in path.split('/')) or
                str(PurePosixPath(path)) != path or path in records or
                kind not in ('handover', 'task-index')):
            refuse('invalid or duplicate record configuration')
        records[path] = kind
    changed = set(trees[base]) | set(trees[head])
    changed = {p for p in changed if trees[base].get(p) != trees[head].get(p)}
    replacements = {}
    other_tasks = set()
    if not validate_records:
        for path, kind in records.items():
            if kind == 'task-index':
                for ref in (base, head, line):
                    if path in trees[ref]:
                        other_tasks.update(index(blob(ref, path), path)[6])
        other_tasks.discard(task)
    for path, kind in records.items():
        if any(p.startswith(path + '/') for r in (base, head, line) for p in trees[r]):
            refuse(f'{path}: shared record is a directory')
        if not any(path in trees[r] for r in (base, head, line)):
            continue
        raw = [blob(ref, path) for ref in (base, head, line)]
        if validate_records:
            validate_preservation(path, kind, raw[1], raw[2])
            continue
        # Parse even unchanged shared files: an unreadable present record is
        # never a reason to rewrite it or silently bypass its safety checks.
        result = handover(path, *raw, other_tasks=other_tasks) if kind == 'handover' else task_index(path, *raw)
        if result != raw[2]:
            oid = git('hash-object', '-w', '--stdin', data=result).stdout.strip().decode()
            replacements[path] = ('100644', 'blob', oid)
    if validate_records:
        return
    stripped = {p: trees[base].get(p) for p in records}
    head_tree, line_tree = write_tree(head, stripped), write_tree(line, stripped)
    head_commit = git('commit-tree', head_tree, '-p', base, data=b'proof\n').stdout.strip().decode()
    line_commit = git('commit-tree', line_tree, '-p', base, data=b'proof\n').stdout.strip().decode()
    merged = git('merge-tree', '--write-tree', line_commit, head_commit, check=False)
    if merged.returncode or merged.stdout.splitlines()[0].decode() != line_tree:
        for path in sorted(changed - set(records)):
            a, b = trees[head].get(path), trees[line].get(path)
            if a != b:
                old = git('cat-file', 'blob', b[2]).stdout if b and b[1] == 'blob' else b''
                new = git('cat-file', 'blob', a[2]).stdout if a and a[1] == 'blob' else b''
                lost(path, old, new)
        refuse('non-record changes are not proven present on the line')
    for path in changed - set(records):
        if (trees[head].get(path) or ('',))[0] != (trees[line].get(path) or ('',))[0]:
            refuse(f'{path}: worker mode is not present on the line')
    result_tree = write_tree(line, replacements)
    original = git('rev-parse', line + '^{tree}').stdout.strip().decode()
    if contained:
        if result_tree != original:
            refuse('task records are absent from the local line')
    elif result_tree == original:
        name = git('symbolic-ref', '--short', 'HEAD').stdout.strip().decode()
        refuse(f'recorded change is already on {name}; nothing to land')
    print(result_tree)


if __name__ == '__main__':
    try:
        project, task, head, line, config_path = sys.argv[1:6]
        contained = sys.argv[6:] == ['--contained']
        validate_records = sys.argv[6:] == ['--validate-records']
        if sys.argv[6:] and not (contained or validate_records):
            refuse('invalid replay arguments')
        base = git('merge-base', head, line).stdout.strip().decode()
        trees = {ref: tree(ref) for ref in (base, head, line)}
        run()
    except (Refusal, ValueError, UnicodeError, OSError, IndexError, TypeError) as error:
        print('REFUSED: record replay: ' + str(error), file=sys.stderr)
        sys.exit(1)
