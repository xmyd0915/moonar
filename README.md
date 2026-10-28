# MoonAr

[![CI](https://github.com/xmyd0915/moonar/actions/workflows/ci.yml/badge.svg)](https://github.com/xmyd0915/moonar/actions/workflows/ci.yml)

MoonAr 是用 MoonBit 编写的通用 Unix ar 归档库与命令行工具。它覆盖普通归档和 GNU thin
归档的读取、创建、编辑、转换、符号索引维护与比较，可用于构建静态库 `.a`、处理构建产物，
以及读取 `.deb` 的外层容器。也支持 Microsoft COFF `.lib` 静态库与导入库。
核心库直接处理字节，不依赖外部 `ar` 程序。

**0.7.1 优化归档比较并修复嵌套 thin 精确预算处理**，提供三平台 39 组性能基准和 macOS 本机消费者。
Clang 的 full LTO、ThinLTO 对象可参与创建、编辑、
thin 归档和格式转换，支持原始 bitcode 与 Mach-O 包装。保留 COFF 双 linker-member、
bigobj、短导入对象、ELF、Mach-O 以及 GNU 直接/嵌套 thin 的完整工作流。

## 创建并使用静态库

安装 [MoonBit 工具链](https://www.moonbitlang.com/download)，native 后端需要 C 编译器。

```sh
git clone https://github.com/xmyd0915/moonar.git
cd moonar
moon update
moon build --target native --deny-warn
```

生成的命令位于 `_build/native/debug/build/cmd/main/main.exe`，Linux 和 macOS 也使用此文件名。
以下用 `moonar` 指代该命令。将两个已有对象创建为带索引的静态库：

```sh
cc -c first.c -o first.o
cc -c second.c -o second.o
moonar create libsample.a first.o second.o
moonar list libsample.a
cc main.c libsample.a -o demo
```

默认自动发现对象中可索引的定义，并使用确定性元数据。修改其中一个对象后：

```sh
cc -c second.c -o second.o
moonar replace libsample.a 1 second.o
moonar move libsample.a 1 0
moonar extract libsample.a 0 copied.o
```

位置是 `list` 给出的**普通成员零基序号**，因此多个同名对象也能分别编辑。
`list --json` 使用相同序号；`inspect` 则展示包含名称表和符号表的物理记录。

无需准备 C 文件即可运行仓库中的 [读取与比较示例](examples/README.md)。完整的真实对象
创建、编辑和链接流程由 [verify_cli.py](tools/verify_cli.py) 自动执行。

## GNU thin 工作流

```sh
moonar create libthin.a first.o second.o --thin
moonar replace libthin.a 1 second.o
moonar convert libthin.a libpacked.a
moonar create libnested.a libpacked.a --thin
```

thin 保存外部成员引用，普通归档保存成员数据。编辑 thin 会保留 thin 存储方式；
`convert` 将成员加载后写成普通归档。`--output` 写到另一个目录时会重新计算引用路径。
thin 创建或追加时，普通归档输入展开为指向其成员头部的 archive-offset 引用；thin 输入展开为
外部引用。读取嵌套引用会缓存共享容器，并检查目标头部、声明长度、循环引用和累计预算。
物化与逻辑比较使用被引用成员的实际名称；直接文件引用保留路径名称。
默认加载范围为归档所在目录及其子目录，真实路径检查会处理符号链接与 Windows 目录联接。
构建目录确需引用父目录时显式加 `--allow-parent-paths`。

`check` 默认校验容器和索引；加 `--external` 会加载全部 thin 成员，核对路径、实际长度和
累计预算。删除已丢失的 thin 成员后仍可重新建立有效索引。

```sh
moonar check libthin.a --external
moonar diff before/libthin.a after/libthin.a --logical --json
moonar diff libthin.a libpacked.a --logical
```

逻辑比较直接支持 thin 与普通归档的任意组合，比较实际加载的内容、元数据、顺序及原索引映射。
`bytes_equal` 始终比较容器字节，因此两个 thin 容器可以字节相同、外部内容不同。
差异中的成员位置仍对应原归档的物理记录，无需先写出临时归档。

## 命令与格式

| 命令 | 功能 |
| --- | --- |
| `list FILE` / `inspect FILE` / `check FILE` | 普通成员列表、物理记录、结构校验 |
| `create OUT [FILES...]` | 创建普通归档；`--thin` 创建 GNU thin |
| `add ARCHIVE FILES... [--at N]` | 追加或从指定位置插入 |
| `replace ARCHIVE INDEX FILE` | 替换一个成员；普通归档保留其原名称 |
| `delete ARCHIVE INDEX...` | 删除指定成员 |
| `move ARCHIVE FROM TO` | 移到最终位置，保留其他成员的相对顺序 |
| `rename ARCHIVE INDEX NAME` | 修改名称；thin 中修改的是外部引用 |
| `extract ARCHIVE INDEX OUT` | 将指定成员写入明确的输出路径 |
| `convert ARCHIVE OUT` | 转换普通归档布局，或将 thin 物化 |
| `index ARCHIVE` | 从对象重新发现符号并建立索引 |
| `diff BEFORE AFTER [--logical]` | 普通归档物理比较；普通/thin 归档的直接逻辑比较 |

写出选项：

- `--format gnu|gnu64|bsd|bsd64|darwin|darwin64|coff`，默认 `gnu`；thin 支持 GNU32/64。
- `--index auto|none`，默认 `auto`。非对象数据可正常打包；已识别但不支持的对象格式
  在自动模式下明确报错。`none` 跳过发现；Darwin 与 COFF 布局仍包含必要的空索引。
- `--output FILE` 将编辑结果写到新路径；新输出存在时需要 `--force`。
- `--preserve-metadata` 保留已有成员的元数据；新输入采用确定性元数据。
- `--big-endian-index` 选择 BSD/Darwin 大端索引，默认小端。
- `--json` 输出结构化结果；文件名以 `-` 开头时使用 `--`。

文件修改在完成校验后写入同目录的独立短名临时文件，再原子发布，避免给长输出文件名追加后缀。
失败保留原文件；新建默认禁止覆盖，
原位编辑允许替换。输出不能覆盖提取源或 thin 依赖成员。native 和 Node.js CLI 提供文件
写入能力；核心库及不依赖文件系统的命令逻辑支持 native、JavaScript、wasm、wasm-gc。
Node.js CLI 使用系统原生真实路径解析，要求 Node.js 20.16+ 或 22.3+。

文件系统路径按宿主规则处理：Windows 支持盘符根目录、反斜杠分隔及盘符相对路径；
POSIX 文件名中的字面反斜杠会保留。归档成员的 `rename` 名称保持原始字节含义，thin
成员引用继续遵循可移植路径规则。JSON 中的输出路径保留调用时的参数拼写。

查询成功退出 0，无效归档退出 1，参数或读取错误退出 2。编辑成功退出 0，失败退出 2。
`diff` 相同退出 0、不同退出 1、输入错误退出 2；逻辑比较还将配对歧义视为不同。
详细约定见 [API 与 JSON](docs/API.md)。

Windows 上使用 `moonar create sample.lib first.obj second.obj --format coff` 创建 Microsoft
静态库；编辑和重建 `.lib` 时同样指定 `--format coff`。bigobj 和短导入对象参与自动索引，
COFF 两份 linker-member 会交叉校验并以第二份的排序映射公开。真实 MSVC 静态链接与 DLL
导入消费者见 [Windows 验证脚本](tools/verify_windows.py)。

## 作为 MoonBit 库使用

```sh
moon add xmyd0915/moonar@0.7.1
```

在 `moon.pkg` 中导入 `"xmyd0915/moonar" @ar`：

```moonbit
let plan = @ar.ArchiveBuilder::from_members([
  @ar.WriteMember::new(b"hello.txt", b"hello\n"),
]).unwrap()
let bytes = plan.write(format=@ar.Gnu).unwrap()
let archive = @ar.parse(bytes).unwrap()
let data = archive.member_bytes(0).unwrap()
```

对象归档使用 `plan.discover_symbols()` 获取最终成员映射，再传给
`plan.write(symbols=Some(symbols))`。thin 使用独立的 `ThinArchiveBuilder` 和 `parse_thin`；
加载器由调用方提供，解析不隐式访问磁盘。`thin.snapshot(loader)` 捕获已加载内容，
再用 `snapshot.compare_logical(other)` 与另一个 thin 快照或 `ordinary.snapshot()` 比较。库接口返回 `Result`，示例中的 `unwrap()`
适用于固定有效输入。详见 [读写 API](docs/WRITING.md) 和 [生成接口](pkg.generated.mbti)。

## 格式范围与比较

| 能力 | 支持范围 |
| --- | --- |
| 读取与写出 | GNU32/64、BSD32/64、Darwin32/64、Microsoft COFF 双索引；BSD/Darwin 支持大小端 |
| thin | GNU 直接文件与嵌套 archive-offset 引用，GNU32/64 索引，创建、编辑、加载、重定位与物化 |
| 自动符号发现 | ELF32/64、Mach-O32/64、标准 COFF、bigobj、短导入对象；带版本 3 摘要表的 LLVM bitcode |
| 成员 | 原始名称字节、长名称、重名、空内容、二进制数据和元数据 |
| 比较 | 物理字节、普通成员内容、元数据、顺序、符号映射与重名配对歧义 |

自动发现保留可索引的全局、弱定义、公共符号和绝对符号，排除未定义与局部符号。
GNU 保留名称可作为长名称普通成员写出；BSD/Darwin 会拒绝与索引记录冲突的名称。
Darwin 的对齐字节可能包含在成员声明大小内，提取时保留，与 LLVM 行为一致。

`diff --logical` 可以识别 GNU 名称表与 BSD 内嵌名称等布局变化，分别报告内容、元数据、
顺序与符号映射。重名成员优先按相同内容配对，无法唯一识别时报告 `ambiguities`。
设计和案例见 [比较说明](docs/COMPARISON.md)。

LLVM bitcode 使用内嵌的版本 3 符号摘要表，读取编译器生成的已修饰名称及全局、弱、公共和
别名定义；过滤局部、未定义和格式专用记录。支持模块组与包装偏移，并检查表范围、字符串、
分组和共享预算。LLVM IR 指令、优化与代码生成由链接工具链处理。

明确的格式边界：缺少支持的摘要表的旧 bitcode、GCC slim LTO 插件解析、fat Mach-O 和
AIX big archive 不在 0.7.1 自动发现范围内。GCC slim 标记会明确报错；fat LTO 的原生符号
仍可使用。库调用方也可提供显式符号映射。
`check` 校验容器和索引结构，`--external` 另检查 thin 外部成员，不等价于对象 ABI 或链接结果验证。目录批量解压、`.deb`
内层 tar 解压、链接器实现和包签名校验不属于本库职责。

## 验证与实际消费者

```sh
moon fmt --check
moon check --target all --deny-warn
moon test --target all --deny-warn
moon build --target native --deny-warn
python tools/verify_cli.py --moonar _build/native/debug/build/cmd/main/main.exe --require-llvm
python tools/verify_io.py --moonar _build/native/debug/build/cmd/main/main.exe
python tools/verify_zlib.py --moonar _build/native/debug/build/cmd/main/main.exe
python tools/verify_windows.py --moonar _build/native/debug/build/cmd/main/main.exe
python tools/verify_lto.py --moonar _build/native/debug/build/cmd/main/main.exe
python tools/verify_package.py
python tools/benchmark.py
```

GNU/LLVM 验证需要 GNU ar/nm、LLVM ar、C 编译器和 Python 3.9+；Windows 专项使用 MSVC。
macOS Apple Silicon 使用 Xcode 命令行工具运行
`python tools/verify_macos.py --moonar _build/native/debug/build/cmd/main/main.exe`：
对照 Apple libtool、ar 与 nm，覆盖四种 BSD/Darwin 布局的全部编辑命令、GNU32/64 thin 和嵌套
thin 物化，并实际执行 16 个链接消费者。保留元数据后核对与 Apple 参考库的完整逻辑比较。
嵌套 thin 与 GNU ar 对照，物化结果再由 LLVM 消费。真实项目验证固定使用
**zlib 1.3.1**：校验源码摘要，编译对象，用 MoonAr 分别创建普通及 thin 静态库，链接执行
压缩/解压往返，再替换对象并重新链接执行。源码在临时目录处理，不随 MoonAr 分发。
完整入口、预期结果及平台范围见 [复现指南](docs/REVIEW.md)。
LTO 验证使用 Clang、LLD、LLVM ar，或 `verify_lto.py --zig PATH`：对照符号映射并完成
普通/thin 创建、编辑、物化与混合原生对象的实际链接运行；嵌套引用先物化再交给 LLD。
发行 ZIP 另通过独立 MoonBit 消费模块验证公开接口。
已发布版本可运行 `python tools/verify_registry.py`，从 MoonCakes 安装后执行同一组公共接口
消费者，并核对安装内容与本地发行 ZIP 的全部文件。详见[发布包验证](docs/REVIEW.md#发布包公共接口)。

[Linux / Windows / macOS Apple Silicon CI](.github/workflows/ci.yml) 固定编译器与 core
`0.10.14+7d59c7ec9`，运行四后端测试、真实文件操作和独立消费者检查。
GNU/LLVM、Python 与 C 编译器仅用于构建或验证；核心库只依赖 MoonBit core。

性能基准覆盖 100/1000/10000 个成员、唯一名称与重名比较，以及深度 1/4/16 的嵌套 thin，共 39 组场景。
每组检查语义结果和缓存加载次数，报告操作耗时的中位数及波动、整个进程的峰值驻留内存。
运行参数、测量范围和报告入口见 [性能基准](docs/PERFORMANCE.md)。

## 资源与文档

默认预算：64 MiB 输入/输出、100,000 条物理记录、64 MiB 展开成员名、1,000,000 个符号、
64 MiB 展开符号名。CLI 通过 `--max-bytes`、`--max-members`、`--max-name-bytes`、
`--max-symbols`、`--max-symbol-name-bytes` 调整。符号发现对扫描数量计费，重复引用按
展开长度计费。大小和偏移使用有符号 32 位整数。

嵌套容器另用 `NestedLimits` 累计限制字节、记录、展开名称和符号；同路径容器每次批量操作
只加载解析一次。CLI 的 `--max-archive-bytes` 默认 64 MiB，`--max-depth` 默认 16、最大 64。
嵌套路径与所解析容器的成员名共用名称预算；COFF 两份索引均计入符号数及名称预算。
同一已解析来源路径在一次批量操作中只计费一次，重复经过该路径不额外消耗名称预算。

thin 内容检查与快照对每个输入的全部外部成员累计使用字节预算，重复引用分别计费。
CLI 先读取完整文件再检查预算；比较、输出和对象发现需要额外内存。当前接口使用内存输入，
不提供流式读写。文件系统路径检查与打开之间存在并发替换窗口，调用方应控制构建目录的写入。

- [读写、thin、自动符号发现与错误](docs/WRITING.md)
- [通用库范围、交付阶段与验收标准](docs/ROADMAP.md)
- [API 与 JSON](docs/API.md)、[代码结构](docs/DEVELOPMENT.md)
- [性能基准与测量方法](docs/PERFORMANCE.md)
- [复现指南](docs/REVIEW.md)、[来源说明](ORIGINS.md)、[版本记录](CHANGELOG.md)

项目使用 [MIT 许可证](LICENSE)。
