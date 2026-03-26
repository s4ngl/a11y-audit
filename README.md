# a11y-audit

Automated accessibility auditing using three tools: **Pa11y-CI** (axe-core + HTMLCS), **Google Lighthouse**, and **WAVE WebAIM API**.

## Quickstart

```bash
chmod +x a11y-audit.sh
./a11y-audit.sh -f urls.txt --install-deps
```

`--install-deps` auto-installs `pa11y-ci` and `lighthouse` via npm if they aren't already present.

## WAVE API (optional)

WAVE is skipped automatically if no key is set. To enable it:

1. Register at [wave.webaim.org/api/register](https://wave.webaim.org/api/register)
2. Copy `a11y-audit.env.txt` to `.env` and paste your key

```bash
cp a11y-audit.env.txt .env
```

## Usage

```
./a11y-audit.sh                          # uses the SITES array in the script
./a11y-audit.sh -f urls.txt              # one URL per line
./a11y-audit.sh -u https://example.com   # single URL
./a11y-audit.sh --skip-pa11y             # skip Pa11y-CI and axe DevTools
./a11y-audit.sh --skip-lighthouse        # skip Lighthouse
./a11y-audit.sh --skip-wave              # skip WAVE
```

## Reports

Results are saved to `a11y-reports/<timestamp>/` after every run. The latest run is archived at [`a11y-reports/latest-report.tar.gz`](a11y-reports/latest-report.tar.gz).

```
a11y-reports/
├── 2026-03-25_18-52-15/
│   ├── summary.txt
│   ├── pa11y/
│   ├── lighthouse/
│   └── wave/
└── latest-report.tar.gz
```
