# MoonAr

[![CI](https://github.com/xmyd0915/moonar/actions/workflows/ci.yml/badge.svg)](https://github.com/xmyd0915/moonar/actions/workflows/ci.yml)

MoonAr 是用 MoonBit 编写的通用 Unix ar 归档库与命令行工具。它覆盖普通归档和 GNU thin
归档的读取、创建、编辑、转换、符号索引维护与比较，可用于构建静态库 `.a`、处理构建产物，
以及读取 `.deb` 的外层容器。核心库直接处理字节，不依赖外部 `ar` 程序。

**0.3.0 提供完整的归档编辑流程**：从 ELF、Mach-O 和标准 COFF 对象发现符号，写出
GNU/BSD/Darwin 归档；追加、插入、替换、删除、移动或重命名后自动重建索引。
GNU thin 支持直接外部文件引用、32/64 位索引、路径重定位和普通归档物化。

## 创建并使用静态库

安装 [MoonBit 工具链](https://www.moonbitlang.com/download)，native 后端需要 C 编译器。

```sh
git clone https://github.com/xmyd0915/moonar.git
cd moonar
moon update
moon build --target native --deny-warn
```

生成的命令位于 `_build/native/debug/build/cmd/main/main.exe`，Linux 也使用此文件名。
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
```

thin 保存外部成员引用，普通归档保存成员数据。编辑 thin 会保留 thin 存储方式；
`convert` 将成员加载后写成普通归档。`--output` 写到另一个目录时会重新计算引用路径。
默认加载范围为归档所在目录及其子目录，真实路径检查会处理符号链接与 Windows 目录联接。
构建目录确需引用父目录时显式加 `--allow-parent-paths`。

`check` 只校验容器和索引，不加载外部文件；自动索引、提取和物化会核对外部文件是否存在、
声明大小是否匹配以及累计数据预算。删除已丢失的 thin 成员后仍可重新建立有效索引。

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
| `diff BEFORE AFTER [--logical]` | 比较普通归档的物理字节或逻辑内容 |

写出选项：

- `--format gnu|gnu64|bsd|bsd64|darwin|darwin64`，默认 `gnu`；thin 支持 GNU32/64。
- `--index auto|none`，默认 `auto`。非对象数据可正常打包；已识别但不支持的对象格式
  在自动模式下明确报错。`none` 跳过发现；Darwin 布局仍包含必要的空索引。
- `--output FILE` 将编辑结果写到新路径；新输出存在时需要 `--force`。
- `--preserve-metadata` 保留已有成员的元数据；新输入采用确定性元数据。
- `--big-endian-index` 选择 BSD/Darwin 大端索引，默认小端。
- `--json` 输出结构化结果；文件名以 `-` 开头时使用 `--`。

文件修改在完成校验后写入同目录临时文件，再原子发布。失败保留原文件；新建默认禁止覆盖，
原位编辑允许替换。输出不能覆盖提取源或 thin 依赖成员。native 和 Node.js CLI 提供文件
写入能力；核心库及不依赖文件系统的命令逻辑支持 native、JavaScript、wasm、wasm-gc。

查询成功退出 0，无效归档退出 1，参数或读取错误退出 2。编辑成功退出 0，失败退出 2。
`diff` 相同退出 0、不同退出 1、输入错误退出 2；逻辑比较还将配对歧义视为不同。
详细约定见 [API 与 JSON](docs/API.md)。

## 作为 MoonBit 库使用

```sh
moon add xmyd0915/moonar@0.3.0
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
加载器由调用方提供，解析不隐式访问磁盘。库接口返回 `Result`，示例中的 `unwrap()`
适用于固定有效输入。详见 [读写 API](docs/WRITING.md) 和 [生成接口](pkg.generated.mbti)。

## 格式范围与比较

| 能力 | 支持范围 |
| --- | --- |
| 读取与写出 | GNU32/64、BSD32/64、Darwin32/64；BSD/Darwin 索引支持大小端 |
| thin | GNU 直接外部文件引用，GNU32/64 索引，创建、编辑、加载、重定位与物化 |
| 自动符号发现 | ELF32/64 与 Mach-O32/64 大小端可重定位对象、标准小端 COFF 对象 |
| 成员 | 原始名称字节、长名称、重名、空内容、二进制数据和元数据 |
| 比较 | 物理字节、普通成员内容、元数据、顺序、符号映射与重名配对歧义 |

自动发现保留可索引的全局、弱定义、公共符号和绝对符号，排除未定义与局部符号。
GNU 保留名称可作为长名称普通成员写出；BSD/Darwin 会拒绝与索引记录冲突的名称。
Darwin 的对齐字节可能包含在成员声明大小内，提取时保留，与 LLVM 行为一致。

`diff --logical` 可以识别 GNU 名称表与 BSD 内嵌名称等布局变化，分别报告内容、元数据、
顺序与符号映射。重名成员优先按相同内容配对，无法唯一识别时报告 `ambiguities`。
设计和案例见 [比较说明](docs/COMPARISON.md)。

明确的格式边界：GNU thin 嵌套 archive-offset 引用、COFF 双 linker-member 归档、
COFF bigobj/import object、LTO/bitcode、fat Mach-O、AIX big archive 不在 0.3.0 支持范围内。
`check` 校验容器和索引结构，不等价于对象 ABI 或链接结果验证。目录批量解压、`.deb`
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
python tools/verify_package.py
```

独立工具验证需要 GNU ar/nm、LLVM ar、C 编译器和 Python 3.9+。真实项目验证固定使用
**zlib 1.3.1**：校验源码摘要，编译对象，用 MoonAr 分别创建普通及 thin 静态库，链接执行
压缩/解压往返，再替换对象并重新链接执行。源码在临时目录处理，不随 MoonAr 分发。
完整入口、预期结果及平台范围见 [复现指南](docs/REVIEW.md)。
发行 ZIP 另通过独立 MoonBit 消费模块验证公开接口。

[Linux / Windows CI](.github/workflows/ci.yml) 固定编译器与 core
`0.10.14+7d59c7ec9`，运行四后端测试、真实文件操作和独立消费者检查。
GNU/LLVM、Python 与 C 编译器仅用于构建或验证；核心库只依赖 MoonBit core。

## 资源与文档

默认预算：64 MiB 输入/输出、100,000 条物理记录、64 MiB 展开成员名、1,000,000 个符号、
64 MiB 展开符号名。CLI 通过 `--max-bytes`、`--max-members`、`--max-name-bytes`、
`--max-symbols`、`--max-symbol-name-bytes` 调整。符号发现对扫描数量计费，重复引用按
展开长度计费。大小和偏移使用有符号 32 位整数。

CLI 先读取完整文件再检查预算；比较、输出和对象发现需要额外内存。当前接口使用内存输入，
不提供流式读写。文件系统路径检查与打开之间存在并发替换窗口，调用方应控制构建目录的写入。

- [读写、thin、自动符号发现与错误](docs/WRITING.md)
- [通用库范围、交付阶段与验收标准](docs/ROADMAP.md)
- [API 与 JSON](docs/API.md)、[代码结构](docs/DEVELOPMENT.md)
- [复现指南](docs/REVIEW.md)、[来源说明](ORIGINS.md)、[版本记录](CHANGELOG.md)

项目使用 [MIT 许可证](LICENSE)。
