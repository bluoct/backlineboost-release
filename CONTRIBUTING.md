# Contributing

Thanks for your interest in Backline Boost.

By submitting a contribution (a pull request, patch, or change) to this project, you agree that your contribution is licensed under the same license as the project — the **GNU General Public License v3.0** (inbound = outbound) — and you certify that you have the right to submit it under that license, per the [Developer Certificate of Origin](https://developercertificate.org). Please sign off your commits (`git commit -s`, which adds a `Signed-off-by: Your Name <you@example.com>` line) to record that certification.

This is a personal portfolio project maintained in spare time, so response times may vary. Bug reports and focused fixes are welcome.

## Building

See [INSTALL.md](INSTALL.md) for the toolchain and helper-tool setup. In short:

```sh
env CLANG_MODULE_CACHE_PATH=.build/module-cache swift build --disable-sandbox
env CLANG_MODULE_CACHE_PATH=.build/module-cache swift test --disable-sandbox
./script/build_and_run.sh --verify
```
