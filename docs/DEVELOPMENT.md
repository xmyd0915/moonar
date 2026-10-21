# 开发说明

## 代码结构

| 文件或目录 | 职责 |
| --- | --- |
| `types.mbt` | 归档、成员、错误与比较结果类型 |
| `parse.mbt` | 普通 ar 头部、数值字段、边界与资源限制 |
| `names.mbt` | GNU 名称表和 BSD 内嵌名称 |
| `symbols.mbt` | GNU/BSD 32/64 位索引、字节序约束、字符串与成员引用校验 |
| `thin.mbt` | GNU thin 的独立容器、外部成员路径和调用者加载器 |
| `write.mbt` | 不可变成员编辑计划、GNU/BSD/Darwin 六种布局和索引写出 |
| `coff_symbols.mbt` / `coff_write.mbt` | Microsoft 双 linker-member 解析、交叉校验与写出 |
| `nested_load.mbt` | 嵌套归档寻址、缓存、依赖枚举、累计预算与循环检查 |
| `object_import.mbt` | bigobj 分类与短导入对象符号发现 |
| `bitcode_stream.mbt` | LLVM 顶层块、摘要缩写、VBR 与零复制 blob 范围 |
| `object_bitcode.mbt` | 版本 3 摘要结构、模块分区、名称与定义筛选 |
| `thin_write.mbt` | thin 成员编辑、GNU32/64 写出、累计预算与物化 |
| `object_symbols.mbt` | ELF/Mach-O/COFF 符号发现、结构约束与跨成员预算 |
| `compare.mbt` | 内容优先配对、歧义报告、物理与逻辑比较、符号映射和顺序判断 |
| `snapshot.mbt` | thin 加载预检、累计预算、只读内容校验与不可变比较快照 |
| `json.mbt` | 版本化 JSON 输出与无损名称表示 |
| `cli/` | 参数解析、命令执行和退出码 |
| `cmd/main/` | native/Node 文件接口、原子发布、真实路径检查与命令行入口 |
| `examples/read_deb/` | 通过公共 API 读取 Debian 包外层的示例 |
| `examples/archive_workflow/` | 创建、编辑、thin 加载和静态库写出的公共 API 消费者 |
| `tools/` | 示例生成与 GNU/LLVM 对照验证 |

解析库接收完整的 `Bytes`，不访问文件系统。CLI 通过可注入的读取、写入和路径函数调用库，
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

成员按类型和原始名称分组，优先匹配完整内容相同的项，再按出现次序处理剩余项。
无法唯一确定身份的组写入 `ambiguities`。字节视图避免复制载荷，哈希碰撞后仍检查完整字节。
`bytes_equal` 包含全部头部与填充字节；
`order_changed` 只考虑两侧已配对记录的相对顺序。内容与元数据的变化标志针对修改项，
不用于解释新增或删除项。详细字段约定见 [API 说明](API.md)。

逻辑比较排除特殊记录，沿普通成员配对转换旧符号引用，再比较符号到成员的映射。
绝对偏移与索引宽度不作为映射差异；同名符号的目标次序保留。
设计和案例见 [比较说明](COMPARISON.md)。

### 符号索引

解析先验证容器和名称，再解码索引。所有整数在转换为偏移和计数前按输入边界检查；
目标必须精确匹配普通成员的头部。BSD 的两种字节序分别接受完整结构约束，结果不同
但都有效时返回 `AR010`。资源预算不足时返回 `AR008`，不通过预算选择另一种解释。
字符串表只扫描一次，重复名称共享不可变字节，但展开后的总长度仍受预算限制。
`symbol_indexes()` 复制两层数组，调用方不能破坏已校验的内部引用。

## 验证方法

- 单元测试覆盖普通记录、GNU/BSD 名称、重名成员、比较、JSON 和 CLI 行为。
- 异常输入测试包含混合归档的逐位置截断、字节变异和资源限制。
- `tools/examples.py` 复核仓库内的五个样本，并检查三个使用场景的输出和退出码。
- `tools/verify_archives.py` 使用 GNU ar 和 LLVM ar 生成归档，将成员列表、顺序及数据与
  独立工具的列举、提取和 GNU nm 符号结果比较；也覆盖真实 C 对象、损坏索引、
  重名插入、跨格式逻辑比较及 GNU/Darwin 64 位索引。
- `tools/verify_workflow.py` 验证写出的 GNU/BSD、重名编辑、GNU/LLVM thin 加载与物化，
  以及 GNU32 映射的 `nm` 结果和真实对象链接运行。
- `tools/verify_cli.py` 从真实对象完成全部编辑命令、六种写出布局、自动索引、
  直接与嵌套 thin32/64 创建、重定位与物化；检查链接运行及可用工具下的 Mach-O 链接。
- `tools/verify_windows.py` 通过 MSVC 验证 COFF 双表、bigobj、短导入对象，静态与 DLL 消费者实际链接运行。
- `tools/verify_io.py` 在 native 与 Node 检查原子发布、并发、Unicode、禁止覆盖、
  失败保留、真实路径范围与输出别名保护。
- `tools/verify_zlib.py` 校验上游 zlib 1.3.1 摘要，编译 15 个对象，创建普通及 thin
  静态库并运行压缩解压；替换对象及物化后重新链接运行。
- `tools/verify_lto.py` 对照 LLVM 摘要映射，验证 full/ThinLTO 编辑、thin 物化、混合原生对象
  与真实链接运行；另检查 GCC slim 拒绝及 fat 对象原生回退。
- Linux 和 Windows CI 运行四个后端的检查与测试、原生构建和示例。Linux 额外运行
  GNU/LLVM 对照，以及 `dpkg-deb --info` 检查 Debian 示例。

对照过程中明确处理了以下需要明确处理的工具行为：

1. LLVM 18.1.3 的 Darwin 布局会把填充计入成员大小。对照脚本据此比较实际提取字节，
   不再假设归档成员大小总是等于归档前的文件大小。
2. Windows 上 GNU ar 2.30 的标准输出会在所测对象文件上转换换行。二进制对照使用
   临时目录中的提取文件，避免终端输出转换影响结果。
3. GNU 长名称表可以包含与索引标识同名的普通文件。解析时保留名称引用的普通成员身份，
   不在解析长名称后重新按字符串分类；写出时强制采用长名称表表示这些成员。
4. Windows 大小写路径和目录联接可能指向同一文件。输出保护比较真实路径，
   同时检查 thin 原始依赖和编辑后的依赖，防止强制输出覆盖对象或提取源。

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
