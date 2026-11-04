"""Common locations for the Python scripts of this repository (same meaning as scripts/env.sh; every value can be overridden by the environment).
usage:  sys.path.insert(0, <repo>/scripts); from ttg_env import G, BIG, ROOT, big, prog"""
import os

ROOT = os.environ.get('RTL_ROOT') or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AI_HUMA_ROOT = os.environ.get('AI_HUMA_ROOT') or os.path.dirname(ROOT)
G = os.environ.get('TTG_PROGS') or os.path.join(AI_HUMA_ROOT, 'trace-model', 'build')       # built test programs (tests/, vm/)
BIG = os.environ.get('TTG_BIG') or os.path.join(ROOT, 'programs', 'big')                     # shortened dhrystone / coremark
TM = os.environ.get('TM') or os.path.join(AI_HUMA_ROOT, 'trace-model', 'build', 'simulator')
BASELINE_SRC = os.environ.get('BASELINE_SRC') or os.path.normpath(
    os.path.join(AI_HUMA_ROOT, '..', 'llm4trace', 'third_party', 'tututugege', 'baseline-sim', 'src'))


def big(name):
    """path of programs/big/<name>.bin"""
    return os.path.join(BIG, name + '.bin')


def prog(entry):
    """resolve one program-list entry (see env.sh)"""
    if entry.startswith('/'):
        return entry
    if entry.startswith('big/'):
        return os.path.join(BIG, entry[4:])
    if entry.startswith('baseline/'):
        return os.path.join(BASELINE_SRC, entry[9:])
    if entry.startswith('tm/'):
        return os.path.join(AI_HUMA_ROOT, 'trace-model', entry[3:])
    return os.path.join(G, entry)
