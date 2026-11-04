# Working on this repo

## Branches
- `main`: always passes the regression (`./run3.sh xrun sweep`).
- Feature branches: `fpga/axil-regs`, `fpga/block-design`, `rtl/registered-fifo`, ...
- Open a pull request into `main`; the other contributor reviews before merging.

## Before opening a PR
- [ ] Regression passes (all PASS)
- [ ] HAL lint shows 0 unexplained findings (new waivers explained in `lint/WAIVERS.md`)
- [ ] Results that changed are updated in `RESULTS.md` / `results/`

## Commit messages
Short imperative summary, e.g. `fpga: add AXI-Lite mode register`.
For work done together, add a trailer so both names show on GitHub:

    Co-authored-by: Name <email-linked-to-their-github>
