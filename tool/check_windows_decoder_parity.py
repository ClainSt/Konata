"""Compare selected SDR frames from real Windows software/hardware render paths."""
import argparse
import json
from pathlib import Path
from check_dovi_windows_sdr import capture, delta

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--hardware', required=True)
p.add_argument('--software', required=True)
p.add_argument('--report', required=True)
p.add_argument('--pts', type=float, default=0)
a = p.parse_args()
size, hw, hw_sha = capture(a.hardware, expected_pts=a.pts)
sw_size, sw, sw_sha = capture(a.software, expected_pts=a.pts)
assert size == sw_size
assert len(set(hw)) > 32
difference = delta(hw, sw)
report = {'hardware': a.hardware, 'software': a.software,
          'hardwareSha256': hw_sha, 'softwareSha256': sw_sha,
          'pts': a.pts, 'maxRgb10Difference': difference, 'thresholdCodes': 1,
          'passed': difference <= 1, 'scope': 'Selected digital SDR render frame; not physical display'}
Path(a.report).write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report))
assert report['passed'], 'Cross-decoder render mismatch'
