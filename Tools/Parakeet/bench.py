#!/usr/bin/env python3
"""Stage private iPhone fixtures and summarize raw Handy/Parakeet comparisons."""
import argparse
import json
from pathlib import Path
import re
import shutil


def distance(left, right):
    row = list(range(len(right) + 1))
    for i, word in enumerate(left, 1):
        next_row = [i]
        for j, other in enumerate(right, 1):
            next_row.append(min(row[j] + 1, next_row[j - 1] + 1,
                                row[j - 1] + (word != other)))
        row = next_row
    return row[-1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    stage = sub.add_parser("stage")
    stage.add_argument("--wav", type=Path, required=True)
    stage.add_argument("--handy-result", type=Path, required=True)
    stage.add_argument("--directory", type=Path, required=True)
    stage.add_argument("--paced", action="store_true")
    report = sub.add_parser("report")
    report.add_argument("results", type=Path)
    report.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "stage":
        args.directory.mkdir(parents=True, exist_ok=True)
        manifest = args.directory / "manifest.json"
        fixtures = json.loads(manifest.read_text()) if manifest.exists() else []
        fixtures = [f for f in fixtures if f["wav"] != args.wav.name]
        shutil.copyfile(args.wav, args.directory / args.wav.name)
        baseline = json.loads(args.handy_result.read_text())
        fixtures.append(dict(wav=args.wav.name, handy=baseline["text"], paced=args.paced))
        manifest.write_text(json.dumps(fixtures, indent=2))
        return
    lines = ["# iPhone Parakeet experiment", "",
             "Word disagreement is against Handy's raw output, not a human ground truth. "
             "Fixtures must use identical audio/VAD input for a controlled comparison.", "",
             "| Audio | Word differences | Exact text match | Compute / audio | Stop | Sampled peak footprint | Thermal start → end |",
             "|---|---:|---|---:|---:|---:|---|"]
    results = json.loads(args.results.read_text())
    for result in results:
        tokens = lambda s: re.findall(r"\w+(?:['’]\w+)*", s.lower())
        a, b = tokens(result["handy"]), tokens(result["text"])
        ratio = (result["inferenceSeconds"] + result["stopSeconds"]) / result["audioSeconds"]
        lines.append(f"| {result['wav']} | {distance(a, b)}/{len(a)} | "
                     f"{result['text'] == result['handy']} | {ratio:.2f}× | "
                     f"{result['stopSeconds']:.2f}s | {result['peakFootprintMB']:.0f} MB | "
                     f"{result['thermalStart']} → {result['thermalEnd']} |")
    lines += ["", "## Timing and battery observations", ""]
    for result in results:
        lines.append(f"- {result['wav']}: {result['audioSeconds']:.2f}s audio, "
                     f"{result['elapsedSeconds']:.2f}s elapsed, "
                     f"{result['inferenceSeconds']:.2f}s in feed calls.")
        if "peakLagSeconds" in result:
            lines.append(f"  Maximum input backlog: {result['peakLagSeconds']:.2f}s "
                         "(meaningful only for realtime-paced fixtures).")
        if result.get("batteryStart", -1) >= 0 and result.get("batteryEnd", -1) >= 0:
            lines.append(f"  Battery: {result['batteryStart']:.0%} → {result['batteryEnd']:.0%}; "
                         f"state {result['batteryState']} (1 unplugged, 2 charging, 3 full).")
    lines += ["", "Thermal states: 0 nominal, 1 fair, 2 serious, 3 critical. "
              "Footprint includes the test host. Short tests and coarse battery snapshots do not establish battery life. "
              "This replay test does not establish background microphone behavior."]
    args.output.write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
