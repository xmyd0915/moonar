# MoonAr

[![CI](https://github.com/xmyd0915/moonar/actions/workflows/ci.yml/badge.svg)](https://github.com/xmyd0915/moonar/actions/workflows/ci.yml)

MoonAr 是用 MoonBit 编写的 Unix ar 归档读取库和命令行工具。它面向构建工具、
制品检查脚本和包分析工具，支持读取普通静态库 `.a`，也能读取 `.deb` 的外层 ar 容器。

库接受字节数据，保留成员顺序、重名成员和原始文件名字节；错误带有代码和字节偏移。
比较接口分别报告内容、元数据和相对顺序变化。调用方可以直接使用这些结果，
无需启动外部 `ar` 或解析它的终端输出。

## 快速运行

需要 [MoonBit 工具链](https://www.moonbitlang.com/download)；native 后端还需要 C 编译器。
CI 固定使用编译器和核心库 `0.10.14+7d59c7ec9`，在 Linux、Windows 上验证。
这个版本是本项目的复现基线，不是赛事规定的最低版本。首次解析依赖需要联网；
依赖就绪后，测试和示例无需网络。

```sh
git clone https://github.com/xmyd0915/moonar.git
cd moonar
moon update
moon run cmd/main --target native -- inspect examples/data/bundle-before.a
moon run cmd/main --target native -- diff examples/data/bundle-before.a examples/data/bundle-time.a
moon run examples/read_deb --target native
```

第二条运行命令会返回退出码 **1**，表示两个归档不同，这是该示例的预期结果。
[三个完整场景](examples/README.md)包括正常输出、损坏输入、元数据与内容差异，以及公共库接口的用法。
示例 `.a` 使用自有文本和二进制数据；真实 C 对象文件的归档另由 GNU/LLVM 对照脚本生成验证。

## 命令行

```text
inspect FILE [--json]         列出物理记录、大小、类型和名称
check FILE [--json]           检查受支持的容器结构
diff BEFORE AFTER [--json]    比较归档字节与成员变化
--help | --version
```

在仓库中用 `moon run cmd/main --target native --` 加上述参数运行。
也可执行 `moon build --target native`，直接使用生成的
`_build/native/debug/build/cmd/main/main.exe`；Linux 上该文件也使用 `.exe` 后缀。

`--max-bytes N` 和 `--max-members N` 可调整限制。文件名以 `-` 开头时，在路径前加 `--`。
文本输出会转义名称中的控制字符；自动化脚本应使用 `--json`。

| 命令 | 0 | 1 | 2 |
| --- | --- | --- | --- |
| inspect / check | 成功 | 容器无效或超出限制 | 参数或文件读取失败 |
| diff | 字节完全相同 | 字节不同 | 参数、读取或任一输入解析失败 |

`check` 只验证支持的 ar 结构，不检查对象文件、符号索引内容或包签名。
`--json` 的解析和读取错误写到标准输出；参数错误仍写到标准错误。

## 作为库使用

```sh
moon add xmyd0915/moonar@0.1.0
```

在调用包的 `moon.pkg` 中声明：

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

`member_bytes(index)` 返回成员数据的副本；越界索引返回 `None`。
`get_member(index)` 返回记录值，不能修改归档内部状态。名称不保证是 UTF-8，
请使用 `entry.name` 或 `name_hex()` 作为标识；`name_text()` 仅用于显示。
完整接口见 [pkg.generated.mbti](pkg.generated.mbti)，文件读取示例见
[examples/read_deb](examples/read_deb/main.mbt)。

## 支持范围与比较语义

- 支持普通 ar、GNU 长名称表、BSD 内嵌名称及 LLVM Darwin 写出的布局。
- 符号表和名称表保留为独立物理记录；符号表内容视为不透明字节。
- 按“记录类型、原始名称、第几次出现”配对。重复名称不会合并；它不是内容寻址匹配，
  在重复项前插入新项可能导致后续项按出现次序重新配对。
- `bytes_equal` 比较全部输入字节。`order_changed` 只比较两边已配对记录的相对顺序，
  单纯新增或删除一项不算重排。特殊记录也参与比较。
- `payload_changed` / `metadata_changed` 只对 `modified` 项有意义。
  头部数字的空格写法或名称编码布局不同，可能只有 `bytes_equal=false`。
- Darwin 可能把填充换行计入声明的数据大小。MoonAr 保留这些字节，
  不猜测并裁掉原始文件末尾；这与 `llvm-ar` 提取出的成员数据相符。

首版不提供归档写入、目录解压、thin archive 外部文件加载、ELF/COFF/DWARF 解析、
ABI 或链接等价判断，也不解压 `.deb` 中的 tar 数据。Windows COFF import library 的
完整兼容性不在当前验证范围内。

## 限制

`parse` 默认限制：输入 64 MiB、100,000 条物理记录、展开后名称合计 64 MiB。
库调用者可通过 `max_bytes`、`max_members`、`max_name_bytes` 调整；限制必须非负。
CLI 只暴露前两个选项，名称总量使用默认限制。

解析使用内存中的完整输入。CLI **先读完整文件，再检查解析限制**，因此 `--max-bytes`
不是文件读取的内存上限。比较与 JSON 输出还需要额外内存。面向更大文件的流式读取
不属于 0.1.0 的范围。

## 验证

```sh
moon fmt --check
moon check --target all --deny-warn
moon test --target all --deny-warn
moon build --target native --deny-warn
python tools/examples.py --moonar _build/native/debug/build/cmd/main/main.exe
python tools/verify_archives.py --moonar _build/native/debug/build/cmd/main/main.exe --require-llvm
```

最后一条需要 Python 3.9+、GNU ar、LLVM ar 和 gcc/cc。它从自有输入生成 GNU、BSD、
Darwin 归档，核对独立工具的成员列表和提取结果，并验证重名、顺序、元数据及真实对象文件变化。
Linux CI 强制运行 LLVM 对照；本地可省略 `--require-llvm`，未安装 LLVM 时会明确显示跳过。
其他测试覆盖错误数字字段、截断、逐字节变异、资源限制和 CLI 退出码。

解析库只使用 MoonBit core；CLI 和文件读取示例使用 `moonbitlang/x@0.5.5`。
Python、GNU/LLVM 是验证工具，不是库的运行依赖。

## 文档、来源与许可

- [JSON 与错误代码](docs/API.md)
- [格式参考、依赖与许可来源](ORIGINS.md)
- [开发与赛事核查记录](docs/DEVELOPMENT.md)
- [MIT 许可证](LICENSE)

本项目独立实现，没有导入旧项目代码或提交历史。Codex 协助了调研、设计、代码、测试和文档；
提交与验证记录反映实际完成的工作。赛事申报仍需参赛者理解项目并亲自撰写，
本仓库的存在和测试通过不代表已经获得赛事验收或奖项。
