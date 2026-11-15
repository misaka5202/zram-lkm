# Changelog

## 版本号说明

这个项目**还没有正式版本**。目前所有发布都是 GitHub pre-release（预览版）。

早期版本用的是 `1.0.x`，但那套号看起来像已经稳定，实际只验证到"能编译 +
单机手动加载"。发布已全部删除，版本重新从 `0.1.0` 开始。

`versionCode` 用日期编码（`v0.1.0` → `20261115`）。老的 `1.0.x` 用的是
`10001`–`10003` 这种小数字；如果新版本继续用小数字，KernelSU 更新器会认为
版本更低而不推送。日期编码天然单调递增，不会再因版本重置而倒退。

## v0.1.0 — 第一个打过 tag 的预览版

`versionCode` 20261115。

模块打包和安装方式重整，算法本身没有变化（仍是 lz4k / lz4kd / lz4k_oplus /
lz4hc / 842，外加 zram_list）。

- **`.ko` 不再放进 `system/lib/modules/`**。KernelSU 只有装了 metamodule 时才挂载
  `system/`，原布局等于给用户加了一个看不见的前提：没装就装完什么都不会发生。
  现在放在模块自己的 `ko/` 目录，`post-fs-data.sh` 直接从那里 insmod。
- **CI 与发布解耦**。`ci.yml` 只编译，产物留 artifact；`release.yml` 只在打 tag
  时运行并强制 `--prerelease`。CI 绿灯不再可能把未验证的产物推给用户。
- 模块目录按 KernelSU 规范整理：`MODDIR=${0%/*}`、去掉 `set_perm*`、新增
  `action.sh`。
- 修 `842` 无法加载：`module_param_named` 写在了被两个编译单元共同 include 的
  头文件里，生成两份同名 sysfs 参数，模块在加载阶段就 `-EEXIST` 失败（连 init
  都跑不到）。
- 修 `zram_list` 只加自己那五个名字：厂商自带的 `zstdp` 已注册却同样看不见，
  现在一并补上；反过来厂商 `backends[]` 里的 `zstdn` / `zstdn_o` 根本没注册，
  现在会被过滤掉，不再误导用户去选一个不存在的算法。
