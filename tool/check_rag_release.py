#!/usr/bin/env python3
"""Check measured mobile release metrics; missing measurements block release."""
import json
import sys


def failures(report):
    errors = []
    if report.get('questionCount', 0) < 60:
        errors.append('Evaluate at least 60 frozen questions.')
    for platform in ('android', 'ios'):
        metrics = report.get(platform, {})
        if metrics.get('buildMode') != 'release' or not metrics.get('device'):
            errors.append(f'{platform}: identify a device and release build.')
        checks = {
            'books': lambda n: n >= 100,
            'readyUiP95Ms': lambda n: n <= 200,
            'hybridP95Ms': lambda n: n < 500,
            'recallAt24': lambda n: n >= 0.9,
            'spoilerLeaks': lambda n: n == 0,
        }
        for name, check in checks.items():
            value = metrics.get(name)
            if type(value) not in (int, float) or not check(value):
                errors.append(f'{platform}: {name} is missing or outside its gate.')
        for current, baseline in [('answerCoverage', 'baselineAnswerCoverage'),
                                  ('citationSupport', 'baselineCitationSupport')]:
            values = (metrics.get(current), metrics.get(baseline))
            if not all(type(v) in (int, float) for v in values) or (values[0] <= values[1] if current == 'answerCoverage' else values[0] < values[1]):
                errors.append(f'{platform}: {current} must improve coverage or preserve citation support against baseline.')
        if metrics.get('corpusVectorsLoadedIntoDart') is not False:
            errors.append(f'{platform}: verify bounded Dart vector memory.')
    return errors


if __name__ == '__main__':
    with open(sys.argv[1], encoding='utf-8') as source:
        errors = failures(json.load(source))
    if errors:
        print('RAG release blocked:\n' + '\n'.join('- ' + error for error in errors))
        sys.exit(1)
    print('RAG release gates passed.')
