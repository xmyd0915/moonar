# MoonAr

[![CI](https://github.com/xmyd0915/moonar/actions/workflows/ci.yml/badge.svg)](https://github.com/xmyd0915/moonar/actions/workflows/ci.yml)

MoonAr 是用 MoonBit 编写的 Unix ar 归档读取、符号索引校验与比较库，附带 `inspect`、`check` 和
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

## 符号索引与跨方言比较

`inspect --json` 的 `symbol_indexes` 包含索引格式、符号原始名称、目标成员索引，以及
名称与引用字段的原始字节偏移。`check` 校验容器与索引结构：指向头部中间、数据区、
特殊记录或文件外部的符号引用返回 `AR009` 和引用字段偏移。

支持 GNU 32/64 位索引和 BSD/Darwin 32/64 位 ranlib 布局。BSD 字节序由完整的边界、
字符串和成员引用约束判断；两种解释都有效但结果不同的输入返回 `AR010`。

```sh
moon run cmd/main --target native -- diff before.a after.a --logical --json
```

默认 `diff` 比较全部字节和物理记录。`--logical` 比较普通成员及符号到成员的映射，
分别给出 `content_equal`、`metadata_changed`、`order_changed`、`symbols_equal` 和
`symbol_index_presence_changed`，同时保留 `bytes_equal`。

同一长名称和内容使用 GNU 名称表或 BSD 内嵌名称时，可以得到 `bytes_equal=false`、
`content_equal=true`。索引宽度和绝对偏移改变，但符号仍指向同一个已配对成员时，
`symbols_equal` 保持为 `true`。同名符号的目标次序仍然参与比较。

重名成员先按相同类型、原始名称和相同内容配对，再按出现次序处理剩余项。
在 `[one, two]` 前插入内容为 `new` 的同名项，只产生一项新增；交换原成员则报告顺序变化。
多个候选内容相同或剩余项无法唯一识别时，`ambiguities` 列出相关成员。
完整设计与可复现案例见 [比较说明](docs/COMPARISON.md)。

## 命令行用法

```text
inspect FILE [--json]         列出物理记录、大小、类型和名称
check FILE [--json]           检查受支持的容器结构
diff BEFORE AFTER [--json] [--logical] 比较归档字节、成员或逻辑映射
--help | --version
```

在仓库中用 `moon run cmd/main --target native --` 加上述参数运行。
也可执行 `moon build --target native`，直接使用生成的
`_build/native/debug/build/cmd/main/main.exe`；Linux 上该文件也使用 `.exe` 后缀。

`--max-bytes N`、`--max-members N`、`--max-name-bytes N`、`--max-symbols N` 和
`--max-symbol-name-bytes N` 可调整解析限制。文件名以 `-` 开头时，在路径前加 `--`。
文本输出会转义名称中的控制字符；自动化脚本可以使用 `--json`。

| 命令 | 退出码 0 | 退出码 1 | 退出码 2 |
| --- | --- | --- | --- |
| inspect / check | 成功 | 容器无效或超出限制 | 参数或文件读取失败 |
| diff | 字节完全相同 | 字节不同 | 参数、读取或任一输入解析失败 |
| diff --logical | 内容、已配对元数据、顺序、索引映射与存在性相同，且配对无歧义 | 任一维度不同或配对有歧义 | 参数、读取或任一输入解析失败 |

JSON 输出包含 `schema_version: 1`。解析和读取错误在 JSON 模式下写到标准输出，
参数错误写到标准错误。字段定义和错误代码见 [API 说明](docs/API.md)。

## 作为库使用

在自己的 MoonBit 项目中添加 [MoonCakes 包](https://mooncakes.io/docs/xmyd0915/moonar)：

```sh
moon add xmyd0915/moonar@0.2.0
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
比较两个已解析的归档可调用 `@ar.compare(before, after)`；逻辑比较使用 `@ar.compare_logical`。
`archive.symbol_indexes()` 返回已校验的符号映射及数组副本，修改返回数组不会破坏内部引用。

名称不保证是 UTF-8。需要保留名称时使用 `entry.name` 或 `name_hex()`；
`name_text()` 仅用于显示。完整接口见 [pkg.generated.mbti](pkg.generated.mbti)，
文件读取和成员数据访问示例见 [read_deb](examples/read_deb/main.mbt)。

## 支持范围

- 普通 ar、GNU 长名称表、BSD 内嵌名称，以及 LLVM Darwin 写出的布局。
- 符号表和名称表保留为独立物理记录。GNU 32/64 位及 BSD 32/64 位大小端索引解码为
  符号到普通成员的引用，SORTED 索引还检查名称顺序。
- 重名项按完整内容优先匹配；哈希碰撞后仍检查字节相等。配对稳定，并明确报告歧义。
- `bytes_equal` 比较全部输入字节；`order_changed` 比较已配对记录的相对顺序，
  单纯新增或删除一项不算重排。特殊记录也参与比较。
- `payload_changed` 和 `metadata_changed` 只对 `modified` 项有意义。
  头部数字的空格写法或名称编码布局不同，可能只有 `bytes_equal=false`。
- Darwin 可能把填充换行计入声明的数据大小。MoonAr 保留这些字节，
  与 `llvm-ar` 提取出的成员数据一致。Darwin 确定性重名归档可能调整时间戳，这类变化
  在内容匹配后仍作为元数据报告。

当前版本不提供归档写入、目录解压、thin archive 外部文件加载、对象文件或 ABI 分析，
也不解压 `.deb` 中的 tar 数据。`check` 检查容器与索引结构，不解析对象内部定义，因此
不证明索引中的符号确由目标对象定义，也不验证链接结果、ABI 或包签名。
多个符号索引及 COFF 双 linker-member 布局返回 `AR010`。

## 资源限制

`parse` 默认允许输入 64 MiB、100,000 条物理记录、展开后成员名 64 MiB、1,000,000 个符号、
展开后符号名 64 MiB。重复引用同一个名称也计入展开后的预算。
库和 CLI 均可调整五项限制，参数必须非负。大小和偏移使用有符号 32 位整数。

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

测试覆盖 GNU/BSD 名称、重名插入与重排、配对歧义、符号索引、BSD 字节序歧义、跨方言比较、
JSON、截断、字节变异、资源限制和 CLI 退出码。同一组测试运行在四个后端上。
Python 3.9+ 用于复核示例文件、预期输出及退出码。

有 GNU ar/nm、LLVM ar 和 gcc/cc 的环境还可运行独立工具对照：

```sh
python tools/verify_archives.py --moonar _build/native/debug/build/cmd/main/main.exe --require-llvm
```

脚本从本项目的输入生成归档，核对成员列表、提取结果和真实 C 对象的符号映射，覆盖
损坏索引、重名插入、跨方言逻辑比较和 GNU/Darwin 64 位索引。Linux CI 强制运行 LLVM 对照；
本地省略 `--require-llvm` 时，
缺少 LLVM 会明确显示跳过。验证范围与实现细节见 [开发说明](docs/DEVELOPMENT.md)。

解析库只使用 MoonBit core；CLI 和文件读取示例使用 `moonbitlang/x@0.5.5`。
Python、GNU ar 和 LLVM ar 用于验证，不是解析库的运行依赖。

## 文档与许可证

- [三个使用场景](examples/README.md)
- [复现指南](docs/REVIEW.md)
- [比较设计与案例](docs/COMPARISON.md)
- [API、JSON 与错误代码](docs/API.md)
- [代码结构与验证说明](docs/DEVELOPMENT.md)
- [来源与实现说明](ORIGINS.md)

项目使用 [MIT 许可证](LICENSE)。
