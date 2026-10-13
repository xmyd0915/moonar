# MoonAr

[![CI](https://github.com/xmyd0915/moonar/actions/workflows/ci.yml/badge.svg)](https://github.com/xmyd0915/moonar/actions/workflows/ci.yml)

MoonAr 是用 MoonBit 编写的 Unix ar 归档读取与比较库，附带 `inspect`、`check` 和
`diff` 命令行工具。它可以读取普通静态库 `.a`，也可以读取 `.deb` 的外层 ar 容器。

它面向构建工具、制品检查脚本和包分析工具：检查归档结构、定位损坏的位置，或判断
两次构建的差异来自成员内容、时间戳等元数据，还是成员顺序。解析库直接处理字节数据，
不启动外部 `ar`，保留重名成员和原始文件名字节，便于其他 MoonBit 程序集成。

## 快速开始

需要 [MoonBit 工具链](https://www.moonbitlang.com/download)；native 后端还需要 C 编译器。
CI 在 Linux 和 Windows 上使用编译器与核心库 `0.10.14+7d59c7ec9` 验证。
首次下载依赖需要联网，依赖就绪后可离线运行测试和示例。

```sh
git clone https://github.com/xmyd0915/moonar.git
cd moonar
moon update
moon run cmd/main --target native -- inspect examples/data/bundle-before.a
```

输出依次为记录索引、类型、数据大小和名称：

```text
0	regular	11	"config.txt"
1	regular	3	"assets.bin"
```

继续比较两个归档：

```sh
moon run cmd/main --target native -- diff examples/data/bundle-before.a examples/data/bundle-time.a --json
```

结果中两个成员的 `metadata_changed` 都为 `true`，`payload_changed` 都为 `false`，
说明成员数据相同、元数据发生了变化。此命令返回 **退出码 1**，表示归档不同。

## 三个使用场景

| 场景 | 输入与操作 | 可观察的结果 |
| --- | --- | --- |
| 检查构建产物 | 用 `inspect` 查看归档，用 `check` 检查截断样本 | 列出成员；损坏样本返回错误代码和字节偏移 |
| 排查构建差异 | 用 `diff` 分别比较时间戳变化和内容变化的样本 | 区分 `metadata_changed` 与 `payload_changed` |
| 读取 Debian 包外层 | 通过公共库接口读取示例 `.deb` | 找到三个外层成员，读取 `debian-binary` 的 `2.0` 标记 |

完整命令与预期结果见 [示例说明](examples/README.md)。示例 `.a` 包含本项目生成的文本和
二进制数据；真实 C 对象文件与符号索引另由 GNU/LLVM 对照脚本验证。
需要集中核对功能与测试时，可从 [复现指南](docs/REVIEW.md) 开始。

## 命令行用法

```text
inspect FILE [--json]         列出物理记录、大小、类型和名称
check FILE [--json]           检查受支持的容器结构
diff BEFORE AFTER [--json]    比较归档字节与成员变化
--help | --version
```

在仓库中用 `moon run cmd/main --target native --` 加上述参数运行。
也可执行 `moon build --target native`，直接使用生成的
`_build/native/debug/build/cmd/main/main.exe`；Linux 上该文件也使用 `.exe` 后缀。

`--max-bytes N` 和 `--max-members N` 可调整解析限制。文件名以 `-` 开头时，在路径前加 `--`。
文本输出会转义名称中的控制字符；自动化脚本可以使用 `--json`。

| 命令 | 退出码 0 | 退出码 1 | 退出码 2 |
| --- | --- | --- | --- |
| inspect / check | 成功 | 容器无效或超出限制 | 参数或文件读取失败 |
| diff | 字节完全相同 | 字节不同 | 参数、读取或任一输入解析失败 |

JSON 输出包含 `schema_version: 1`。解析和读取错误在 JSON 模式下写到标准输出，
参数错误写到标准错误。字段定义和错误代码见 [API 说明](docs/API.md)。

## 作为库使用

在自己的 MoonBit 项目中添加 [MoonCakes 包](https://mooncakes.io/docs/xmyd0915/moonar)：

```sh
moon add xmyd0915/moonar@0.1.0
```

在调用包的 `moon.pkg` 中声明导入：

```moonbit
import {
  "xmyd0915/moonar" @ar,
}
```

```moonbit
fn inspect_bytes(input : Bytes) -> Unit {
  match @ar.parse(input) {
    Ok(archive) => {
      for i = 0; i < archive.member_count(); i = i + 1 {
        let entry = archive.get_member(i).unwrap()
        println("\{entry.name_hex()}: \{entry.size} bytes")
      }
    }
    Err(error) => println("\{error.code} at byte \{error.offset}")
  }
}
```

`parse` 返回 `Result[Archive, ParseError]`。成功后可用 `get_member(index)` 读取成员信息，
用 `member_bytes(index)` 取得数据副本；两者在索引越界时均返回 `None`。
比较两个已解析的归档可调用 `@ar.compare(before, after)`。

名称不保证是 UTF-8。需要保留名称时使用 `entry.name` 或 `name_hex()`；
`name_text()` 仅用于显示。完整接口见 [pkg.generated.mbti](pkg.generated.mbti)，
文件读取和成员数据访问示例见 [read_deb](examples/read_deb/main.mbt)。

## 支持范围

- 普通 ar、GNU 长名称表、BSD 内嵌名称，以及 LLVM Darwin 写出的布局。
- 符号表和名称表保留为独立物理记录；符号表内容作为不透明字节处理。
- 归档比较按“记录类型、原始名称、第几次出现”配对，重复名称不会合并。
  在重复项前插入新项，可能改变后续项的配对结果。
- `bytes_equal` 比较全部输入字节；`order_changed` 比较已配对记录的相对顺序，
  单纯新增或删除一项不算重排。特殊记录也参与比较。
- `payload_changed` 和 `metadata_changed` 只对 `modified` 项有意义。
  头部数字的空格写法或名称编码布局不同，可能只有 `bytes_equal=false`。
- Darwin 可能把填充换行计入声明的数据大小。MoonAr 保留这些字节，
  与 `llvm-ar` 提取出的成员数据一致。

当前版本不提供归档写入、目录解压、thin archive 外部文件加载、对象文件或 ABI 分析，
也不解压 `.deb` 中的 tar 数据。`check` 检查容器结构，不验证链接结果、符号索引内容或包签名。
Windows COFF import library 的完整兼容性尚未验证。

## 资源限制

`parse` 默认允许输入 64 MiB、100,000 条物理记录、展开后名称合计 64 MiB。
库调用者可通过 `max_bytes`、`max_members`、`max_name_bytes` 调整，参数必须非负。
CLI 提供前两个选项，名称总量使用默认限制。

CLI **先读完整文件，再检查解析限制**，因此 `--max-bytes` 不是文件读取的内存上限。
比较和 JSON 输出还需要额外内存。当前版本使用完整的内存输入，不支持流式读取。

## 测试与复现

```sh
moon fmt --check
moon check --target all --deny-warn
moon test --target all --deny-warn
moon build --target native --deny-warn
python tools/examples.py --moonar _build/native/debug/build/cmd/main/main.exe
moon run examples/read_deb --target native
```

测试覆盖 GNU/BSD 名称、重复成员、内容与元数据比较、JSON、错误数字字段、截断、
字节变异、资源限制和 CLI 退出码。同一组逻辑测试运行在 wasm、wasm-gc、JavaScript 和 native 上。
Python 3.9+ 用于复核示例文件、预期输出及退出码。

有 GNU ar、LLVM ar 和 gcc/cc 的环境还可运行独立工具对照：

```sh
python tools/verify_archives.py --moonar _build/native/debug/build/cmd/main/main.exe --require-llvm
```

脚本从本项目的输入生成归档，逐项比较 GNU/LLVM 的成员列表和提取结果，并检查真实 C
对象文件的归档变化。Linux CI 强制运行 LLVM 对照；本地省略 `--require-llvm` 时，
缺少 LLVM 会明确显示跳过。验证范围与实现细节见 [开发说明](docs/DEVELOPMENT.md)。

解析库只使用 MoonBit core；CLI 和文件读取示例使用 `moonbitlang/x@0.5.5`。
Python、GNU ar 和 LLVM ar 用于验证，不是解析库的运行依赖。

## 文档与许可证

- [三个使用场景](examples/README.md)
- [复现指南](docs/REVIEW.md)
- [API、JSON 与错误代码](docs/API.md)
- [代码结构与验证说明](docs/DEVELOPMENT.md)
- [来源与实现说明](ORIGINS.md)

项目使用 [MIT 许可证](LICENSE)。
