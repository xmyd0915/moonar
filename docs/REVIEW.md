# 复现指南

从仓库根目录执行。需要 MoonBit `0.10.14+7d59c7ec9`、C 编译器和 Python 3.9+。
独立工具验证另需 GNU ar/nm、LLVM ar；真实项目脚本使用 GCC。

## 构建与基础测试

```sh
moon update
moon fmt --check
moon check --target all --deny-warn
moon test --target all --deny-warn
moon build --target native --deny-warn
moon build --target js --deny-warn
python tools/examples.py --moonar _build/native/debug/build/cmd/main/main.exe
moon run examples/read_deb --target native
```

四个后端为 native、JavaScript、wasm、wasm-gc。基础示例检查普通读取、截断定位、
元数据与内容差异、Debian 外层成员；预期数据见 [示例说明](../examples/README.md)。

## 独立格式与完整编辑流程

```sh
python tools/verify_archives.py --moonar _build/native/debug/build/cmd/main/main.exe --require-llvm
python tools/verify_workflow.py --workflow _build/native/debug/build/examples/archive_workflow/archive_workflow.exe --require-llvm
python tools/verify_cli.py --moonar _build/native/debug/build/cmd/main/main.exe --require-llvm
```

| 脚本 | 核对内容 |
| --- | --- |
| `verify_archives.py` | 参考工具生成归档，MoonAr 读取；列表、提取、重名、索引、损坏引用、逻辑比较和 thin 元数据 |
| `verify_workflow.py` | 公共库示例创建与编辑，独立工具提取，加载 thin 并物化，显式映射写出后真实链接 |
| `verify_cli.py` | 全部编辑命令、六种布局与字节序、自动符号发现、GNU32/64 thin、重定位、缺失成员删除、真实链接运行 |

支持 `--ar`、`--nm`、`--cc`、`--llvm-ar` 显式指定工具。完整 CLI 脚本在有 Clang 时
额外生成 Mach-O 对象；提供 `--zig` 可验证四种 BSD/Darwin 布局的 Mach-O 链接。
跨目标 Mach-O 链接产物在 Windows/Linux 上不执行，不能把链接成功表述为本机运行成功。

GNU/LLVM 对照使用临时目录实际提取二进制，避免 Windows 旧 GNU ar 的标准输出换行转换。
Darwin 声明在载荷内的填充保留；BSD/Darwin 原始对象符号独立于归档映射作参照。
没有 LLVM 时不带 `--require-llvm` 可以运行其余检查，跳过项会明确输出。

## 文件发布与路径回归

```sh
python tools/verify_io.py --moonar _build/native/debug/build/cmd/main/main.exe --node-entry _build/js/debug/build/cmd/main/main.js
```

在 native 和 Node 两个真实文件入口检查：Unicode 名称与二进制内容、新建禁止覆盖、
`--force`、失败保留原字节、两进程竞争只有一个成功、临时文件清理、目录联接/符号链接
真实路径范围、允许父目录访问、提取源和 thin 依赖的输出别名保护。
Windows 增加大小写别名，POSIX 检查替换后权限保留。路径能力因平台受限时脚本明确报出。

## zlib 真实构建消费者

```sh
python tools/verify_zlib.py --moonar _build/native/debug/build/cmd/main/main.exe --cc gcc
```

脚本下载固定的 zlib 1.3.1 并核对 SHA-256；离线使用可添加
`--source-archive /path/to/zlib-1.3.1.tar.gz`，仍执行相同摘要检查。
来源及许可证见 [ORIGINS](../ORIGINS.md)。

1. 编译上游 15 个 C 源文件，不链接系统 zlib。
2. 用 MoonAr 默认自动发现符号，分别创建普通与 thin 静态库。
3. 链接消费者，对 131072 字节输入在压缩级别 1 与 9 下执行压缩、解压和逐字节校验。
4. 重新编译 `deflate.o` 并替换成员，提取核对替换结果，再链接运行两种库。
5. 将 thin 物化为普通归档，再次链接运行。

共执行五个消费者，每个运行两种压缩级别。此流程不调用外部归档工具，也不手工提供符号表。

## 发布包公共接口

```sh
python tools/verify_package.py
```

脚本先生成实际发行 ZIP，再从 ZIP 建立独立消费模块。五项公开接口测试在四个后端运行，
覆盖六种格式、自动索引、thin 创建/编辑/加载/物化、普通成员插入和返回数组隔离。
验证报告写到 `_build/verification/package-consumer.json`，包含版本与包摘要。

## 验收边界与持续集成

[CI](../.github/workflows/ci.yml) 在 Linux/Windows 跑四后端测试、native/Node 文件检查和
公共 API 示例；Linux 安装明确的 GNU/LLVM/Clang/GCC 工具链，运行所有参考与 zlib 流程。
提交对应结果见 [Actions](https://github.com/xmyd0915/moonar/actions)。

结构检查与对象发现承担不同职责：`check` 验证容器和索引引用，自动发现验证所支持的对象
符号结构；实际可链接性由消费者检查。错误输入不被静默跳过。JSON `list` 的普通成员序号
可直接传入编辑命令，`inspect` 则保留物理记录位置。

当前格式范围、未支持的变体及资源模型见 [README](../README.md)，完整验收矩阵见
[范围与阶段](ROADMAP.md)。源码阅读入口为 [类型](../types.mbt)、[thin](../thin.mbt)、
[写出](../write.mbt)、[对象符号](../object_symbols.mbt)、[CLI](../cli/manage.mbt)。
