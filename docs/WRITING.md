# 创建、编辑与 thin 成员

这些接口通过公共包 `xmyd0915/moonar` 使用。核心库只处理字节和成员序列，
文件读写由调用方负责；可运行消费者见 [archive_workflow](../examples/archive_workflow/README.md)。

## 创建普通归档

`WriteMember::new(name, data, metadata?)` 接受原始名称和数据字节。
`ArchiveBuilder::new()` 创建空编辑计划，`append` 返回添加成员后的新计划。
批量创建使用 `ArchiveBuilder::from_members(entries)`，一次复制并校验成员数组，
避免逐项追加时反复复制序列。
`write(format=Gnu)` 写出 GNU 归档，`format=Bsd` 使用 BSD 内嵌名称。
GNU 自动去重并生成长名称表，BSD 将名称长度计入存储大小；两者重算头部和奇数对齐。

```moonbit
let plan = @ar.ArchiveBuilder::new()
let plan = plan.append(@ar.WriteMember::new(b"same.txt", b"first")).unwrap()
let plan = plan.append(@ar.WriteMember::new(b"same.txt", b"second")).unwrap()
let bytes = plan.write(format=@ar.Gnu).unwrap()
```

示例中的 `unwrap()` 适用于固定有效输入；处理外部输入时应匹配 `Result` 的错误分支。
`WriteError` 包含稳定代码、可选普通成员序号 `member_index` 和说明。

默认 `metadata=Deterministic` 输出时间戳、UID、GID 为零，模式为 `0644`。
`metadata=Preserve` 保留传入的字段，`None` 写为空格。写出器检查数字非负且能放入头部字段。
空名称、NUL 和格式保留名称不能作为普通成员；GNU 长名称不能包含换行。
BSD 可以保存含换行的名称。名称本身不要求 UTF-8。

## 编辑与重名成员

`archive.edit()` 导入普通成员，自动移除由写出器重建的名称表。
若原归档存在符号索引，此调用返回 `WR004`；调用方必须明确使用
`archive.edit(drop_symbol_indexes=true)`，再决定是否提供新的符号映射。

| 方法 | 语义 |
| --- | --- |
| `append(entry)` | 追加一个普通成员 |
| `replace(index, entry)` | 替换该位置的名称、内容和元数据 |
| `remove(index)` | 删除该位置的成员 |
| `move_member(from, to)` | 移动到最终位置 `to`，其余成员保持相对顺序 |
| `members()` | 取得成员数组副本 |

所有编辑位置都是**普通成员序列的零基序号**，不含名称表或符号表，
与 `Archive.get_member` 的物理记录序号不同。相同名称的多个成员保持独立身份。
操作返回新的 `ArchiveBuilder`，不会改变原计划；无效位置或字段返回错误。
替换可用于重命名或修改元数据。重建保证指定的逻辑成员，不保证原始头部空格和特殊记录逐字节不变。

## 写出符号索引

最终 `write` 可以接收 `symbols=Some([...])`，每个 `WriteSymbol` 包含：

- `name : Bytes`：非空且不含 NUL 的符号名称；
- `member_index : Int`：最终编辑计划中的普通成员序号。

符号映射必须在全部编辑之后提供。写出器先计算索引、名称表和全部成员头部的位置，
再生成 GNU32 大端索引；同名符号和输入映射顺序原样保留。
`None` 表示不生成索引，`Some([])` 表示生成一个空索引。
BSD 格式同时请求索引会返回 `WR005`。

这一接口编码调用者给定的映射，不从对象文件发现符号。自动符号发现和其他索引格式
见 [交付计划](ROADMAP.md)。示例使用真实对象文件及其已知符号，并由
`nm`、C 编译器和链接器检查输出。

## thin 元数据与外部数据

`parse_thin(bytes)` 读取 GNU thin，返回 `Result[ThinArchive, ParseError]`。
普通归档继续使用 `parse`，两种类型不混用。

| 接口 | 结果 |
| --- | --- |
| `member_count()` / `get_member(index)` | 物理记录数量和 `ThinMember`，包含特殊记录 |
| `symbol_indexes()` | 已校验的 GNU32/64 符号引用；目标使用物理记录序号 |
| `inline_bytes(index)` | 名称表/符号表的内嵌字节；普通成员或无效序号返回 `None` |
| `member_path(index)` | 符合默认策略的相对文件路径 |
| `load_member(index, loader, max_bytes?)` | 调用加载器后核对返回字节和声明大小 |

普通成员的 `ThinMember.size` 表示外部文件的声明大小；这类成员在容器中仅占头部，
奇数外部大小也不产生内嵌对齐字节。名称和符号表则仍存储在归档内。
GNU `/name-offset:archive-offset` 嵌套归档引用及 BSD 内嵌名称返回 `AR011`。

`member_path` 去除 `.` 和重复分隔符，拒绝绝对路径、父目录、反斜杠、
驱动器/数据流前缀和以目录形式结尾的路径。原始名称始终可通过 `get_member` 读取，
因此采用其他工作区策略的调用方可以自行处理引用。

加载器类型为 `(Bytes, Int) -> Result[Bytes, String]`，接收规范化路径和声明字节数。
库在调用前检查声明大小预算，调用后检查实际返回长度。
文件根目录、链接解析以及读取过程的内存限制由加载器负责。
默认库接口不会把路径直接交给文件系统。示例采用显式“成员名→已读取字节”表。

同长度的外部文件仍可能发生内容变化；thin 描述的是引用，实际内容以加载时返回的字节为准。
未加载的 thin 引用不参与普通归档的内容比较。示例可将已加载成员写为普通归档后比较。

## 资源与错误

`parse_thin` 沿用 `parse` 的五项预算及默认值，`max_bytes` 只计算 thin 容器。
`load_member` 默认单个外部成员上限为 64 MiB；批量加载的总预算由调用方管理。
`write` 同样接受五项预算，计算最终输出字节、物理记录、展开名称和符号。
输出缓冲区在布局检查完成后分配。现有大小和偏移上限为有符号 32 位整数。

| 代码 | 含义 |
| --- | --- |
| `AR011` | 不支持的 thin 引用编码，或请求的记录不是有效外部成员 |
| `AR012` | 外部路径不符合默认相对文件策略 |
| `AR013` | 加载器返回失败 |
| `AR014` | 返回内容长度与 thin 声明大小不一致 |
| `AR008` | 解析或加载预算超限、预算参数非法 |
| `WR001` | 普通成员名称或编辑位置非法 |
| `WR002` | 元数据不能表示为头部字段 |
| `WR003` | 写出预算超限或预算参数非法 |
| `WR004` | 导入已有索引需要显式策略 |
| `WR005` | 符号名称、目标或索引格式请求非法 |

创建和编辑返回字节，不直接覆盖文件。文件级事务与完整编辑命令按
[阶段计划](ROADMAP.md) 交付。
