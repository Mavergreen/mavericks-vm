# mavericks-vm

This README has not been read or edited by a human yet.

Run commands in a KVM-accelerated Mac OS X 10.9.5 guest on a GitHub Linux runner, the way
[vmactions](https://github.com/vmactions/freebsd-vm) runs FreeBSD.

```yaml
jobs:
  on-target:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v7
      - uses: Mavergreen/mavericks-vm@v1
        with:
          image-key: ${{ secrets.MAVERICKS_VM_KEY }}
          run: |
            sw_vers
```

The guest is built by [packer-plugin-macosx](https://github.com/Mavergreen/packer-plugin-macosx)
and cached privately, encrypted, for Mavergreen repos only. It is never published: it contains
Apple's operating system.

The inputs are vmactions' (`run`, `prepare`, `envs`, `mem`, `cpu`, `nat`, `sync`, `copyback`, ...),
plus `image-key` and `cpu-model`. A pull request from a fork receives no secrets, so it cannot
run Mavericks tests.
