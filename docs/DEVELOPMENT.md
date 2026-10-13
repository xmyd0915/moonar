# 开发说明

## 代码结构

| 文件或目录 | 职责 |
| --- | --- |
| `types.mbt` | 归档、成员、错误与比较结果类型 |
| `parse.mbt` | 普通 ar 头部、数值字段、边界与资源限制 |
| `names.mbt` | GNU 名称表和 BSD 内嵌名称 |
| `compare.mbt` | 成员配对、数据与元数据比较、相对顺序判断 |
| `json.mbt` | 版本化 JSON 输出与无损名称表示 |
| `cli/` | 参数解析、命令执行和退出码 |
| `cmd/main/` | 原生文件读取与命令行入口 |
| `examples/read_deb/` | 通过公共 API 读取 Debian 包外层的示例 |
| `tools/` | 示例生成与 GNU/LLVM 对照验证 |

解析库接收完整的 `Bytes`，不访问文件系统。CLI 通过可注入的读取函数调用解析库，
参数和错误处理可以在测试中使用内存数据。公共接口由 `moon info` 生成到
[pkg.generated.mbti](../pkg.generated.mbti)。

## 实现约定

### 归档存储与访问

`Archive` 隐藏内部记录数组，只能通过成功解析获得。调用方可读取成员记录和数据副本，
不能修改内部数组而破坏已检查的偏移。偏移以原始输入中的字节位置表示，成员索引包含
符号表和名称表等特殊记录。

### 名称解析

成员名保留为字节，不假设 UTF-8。GNU 长名称引用必须指向名称表条目的起点；名称表会
完整检查，但只为实际引用的条目保留查询记录，避免为大量未使用名称分配对象。
BSD 内嵌名称占用的字节从成员数据范围中扣除。

### 内容与填充

普通奇数长度成员后的对齐字节不计入数据。LLVM Darwin 布局可能把填充换行计入头部声明的
大小，解析结果保留这些字节，不能根据源文件长度推断并删除。

### 比较

成员按类型、原始名称和出现次序配对。`bytes_equal` 包含全部头部与填充字节；
`order_changed` 只考虑两侧已配对记录的相对顺序。内容与元数据的变化标志针对修改项，
不用于解释新增或删除项。详细字段约定见 [API 说明](API.md)。

## 验证方法

- 单元测试覆盖普通记录、GNU/BSD 名称、重名成员、比较、JSON 和 CLI 行为。
- 异常输入测试包含混合归档的逐位置截断、字节变异和资源限制。
- `tools/examples.py` 复核仓库内的五个样本，并检查三个使用场景的输出和退出码。
- `tools/verify_archives.py` 使用 GNU ar 和 LLVM ar 生成归档，将成员列表、顺序及数据与
  独立工具的列举和提取结果比较；也覆盖真实 C 对象、符号索引和确定性模式。
- Linux 和 Windows CI 运行四个后端的检查与测试、原生构建和示例。Linux 额外运行
  GNU/LLVM 对照，以及 `dpkg-deb --info` 检查 Debian 示例。

对照过程中曾发现两个需要明确处理的工具行为：

1. LLVM 18.1.3 的 Darwin 布局会把填充计入成员大小。对照脚本据此比较实际提取字节，
   不再假设归档成员大小总是等于归档前的文件大小。
2. Windows 上 GNU ar 2.30 的标准输出会在所测对象文件上转换换行。二进制对照使用
   临时目录中的提取文件，避免终端输出转换影响结果。

这些检查覆盖已列出的布局与输入，不能据此推断全部历史 ar 变体、对象格式或链接行为均受支持。
具体提交的运行结果可在 [GitHub Actions](https://github.com/xmyd0915/moonar/actions) 查看。

## 本地检查

```sh
moon info
moon fmt
moon check --target all --deny-warn
moon test --target all --deny-warn
moon build --target native --deny-warn
python tools/examples.py --moonar _build/native/debug/build/cmd/main/main.exe
moon run examples/read_deb --target native
```

修改公共接口后检查 `.mbti` 差异。涉及格式兼容时，还应运行 README 中的 GNU/LLVM
对照命令。新增回归测试应有明确的预期字节、格式依据或独立工具结果。

现有内存模型与格式限制见 [README](../README.md)，依赖、参考资料与示例来源见
[ORIGINS.md](../ORIGINS.md)。
