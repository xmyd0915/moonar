# 创建、编辑、thin 与自动索引

公共包 `xmyd0915/moonar` 处理字节和成员序列，文件读写由调用方负责。
命令行是同一套公共接口的文件消费者，完整操作见 [README](../README.md)。

## 普通归档创建与编辑

`WriteMember::new(name, data, metadata?)` 接受原始名称和数据字节。
`ArchiveBuilder::from_members(entries)` 批量校验并复制成员序列，`new()` 创建空计划。

```moonbit
let plan = @ar.ArchiveBuilder::from_members([
  @ar.WriteMember::new(b"same.txt", b"first"),
  @ar.WriteMember::new(b"same.txt", b"second"),
]).unwrap()
let bytes = plan.write(format=@ar.Gnu).unwrap()
```

| 编辑方法 | 行为 |
| --- | --- |
| `append(entry)` | 追加成员 |
| `insert(index, entry)` | 在 `0..member_count()` 位置插入 |
| `replace(index, entry)` | 替换名称、内容和元数据 |
| `remove(index)` | 删除成员 |
| `move_member(from, to)` | 移到最终位置 `to` |
| `members()` | 返回成员数组副本 |

所有位置是**普通成员零基序号**，不包含名称表和符号表。操作返回新的计划，不修改原计划；
重名成员保持独立。`archive.edit()` 导入普通成员并移除旧名称表。若存在符号索引，需显式
使用 `drop_symbol_indexes=true`；否则返回 `WR004`。最终写出重建布局和索引，不保留旧偏移。

`WriteFormat` 包含 `Gnu`、`Gnu64`、`Bsd`、`Bsd64`、`Darwin`、`Darwin64`、`Coff`。
默认 `metadata=Deterministic` 写时间戳、UID、GID 为零，模式为 `0644`。
`metadata=Preserve` 保留输入字段，空字段写空格；数值必须非负且能装入字段。
Darwin 遵循八字节对齐，并为确定性重名成员分配递增时间戳。

名称不能为空或含 NUL。GNU 长名称不能含换行；与特殊记录同名的普通文件通过长名称表
表达。BSD/Darwin 拒绝这些保留名称，可保存其他包含换行的名称。名称无需为 UTF-8。
Darwin 计入载荷的填充会在读取及提取时保留。COFF 长名称使用 NUL 分隔，支持换行；
Microsoft 导入库的 `-1` 时间戳读为 `None`，以语义上的未知时间写出。

## 显式映射与自动发现

`write(symbols=Some(mappings))` 写出索引，每个 `WriteSymbol` 含 `name : Bytes` 和最终
普通成员序号 `member_index : Int`。索引偏移由最终布局计算，调用方不必计算文件偏移。
GNU 使用大端；BSD/Darwin 使用 `index_little_endian` 选择字节序，默认为 `true`。
`None` 不生成索引，`Some([])` 生成空索引；Darwin 始终包含至少一个空索引。
COFF 始终写出两份 linker-member：第一份大端偏移，第二份小端成员表、16 位序号与
按字节词典序排序的名称。最多 65535 个普通成员；两份表均计入符号及名称预算。
解析交叉检查两份映射，`symbol_indexes()` 仅公开第二份规范映射，`record_index=1`、
`format="coff"`；物理记录中仍保留两份表。

```moonbit
let symbols = plan.discover_symbols().unwrap()
let bytes = plan.write(format=@ar.Gnu64, symbols=Some(symbols)).unwrap()
```

`ArchiveBuilder::discover_symbols` 扫描最终成员，返回映射；单个对象可调用
`symbols_from_object(bytes)`。支持：

- ELF32/64，大小端，可重定位对象；全局、弱、公共、绝对、GNU unique 定义和扩展节号。
- Mach-O32/64，大小端，`MH_OBJECT` 的符号表；外部定义、弱/公共/绝对及可索引别名。
- 标准小端 COFF 对象，包括辅助记录、长名称和可解析的弱别名；不把 BSS 虚拟大小当作文件数据。
- COFF bigobj，包括 32 位节号与 20 字节符号；短导入对象覆盖 code/data/const 与五种名称模式。
  code 生成原符号和 `__imp_` 定义，data/const 生成 `__imp_` 定义。
- LLVM bitcode，使用内嵌版本 3 IR 符号摘要；原始流和 bitcode wrapper，单模块或多模块组。
  使用编译器提供的已修饰名称，读取全局、弱、公共和别名定义；过滤局部、未定义与格式专用项。

排除未定义、局部及不适合归档索引的记录；同一对象内重复名称按首次出现去重，跨成员同名
符号保持顺序。非对象数据返回空符号数组；已识别的损坏对象返回 `OB001`，不支持的对象
布局返回 `OB002`。PE、fat Mach-O、wasm 和归档容器
不作为普通可索引对象处理。不能将不支持的已识别对象静默当成空符号对象。

`max_symbols` 默认 1,000,000，按扫描记录计费，包括被过滤的符号；
`max_symbol_name_bytes` 默认 64 MiB，按展开名称计费。Builder 在全部成员间共享预算，
避免每个对象各用一份上限。对象失败转为含成员位置的 `WR006`，预算失败转为 `WR003`。

bitcode 的摘要范围、字符串、comdat、模块分区、uncommon 记录和位流边界均会检查；
IR 指令不被解码，也不重新计算编译器的修饰规则。摘要块最多 256 个本地缩写，每个缩写最多
64 个字段；超过结构上限返回 `OB003`。不支持依赖外部 BLOCKINFO 缩写的摘要编码。
缺少支持的版本 3 摘要表时返回 `OB002`，可通过显式映射写出归档。

GCC slim LTO 的原生符号表只含插件标记，不能据此生成有效索引；检测到
`__gnu_lto_slim` 或其前导下划线变体时返回 `OB002`。fat LTO 对象的原生定义继续使用。
库调用方可以从工具链插件获取映射，再传给 `write(symbols=Some(...))`。

## thin 读取与加载

`parse_thin(bytes)` 返回独立 `ThinArchive`。普通归档使用 `parse`，类型不混用。

| 接口 | 行为 |
| --- | --- |
| `member_count()` / `get_member(index)` | 包含特殊记录的物理位置与成员信息 |
| `symbol_indexes()` | GNU32/64 索引，目标为物理成员位置 |
| `inline_bytes(index)` | 取得名称/符号表字节；普通成员返回 `None` |
| `member_path(index, allow_parent_paths?)` | 检查外部引用路径 |
| `load_member(index, loader, max_bytes?, allow_parent_paths?)` | 加载并核对声明大小 |
| `materialize(loader, drop_symbol_indexes?, allow_parent_paths?, max_bytes?)` | 批量加载为普通 `ArchiveBuilder` |
| `resolve_member(index, loader, ...)` | 返回实际名称、内容和外层元数据组成的 `WriteMember` |
| `member_sources(loader, ...)` | 遍历依赖路径，读取容器元数据但不打开直接成员文件 |

外部成员的声明大小不占据容器字节，也不导致容器奇数补齐。名称表与索引仍内嵌。
支持直接文件与 GNU `/name-offset:archive-offset` 引用；`ThinMember.archive_member_offset`
区分两者。嵌套偏移必须精确指向普通成员头部，声明长度必须一致，容器可继续引用 thin。
BSD 内嵌名称不属于 GNU thin 编码，返回 `AR011`。

默认路径策略拒绝绝对路径、父目录、反斜杠、驱动器/数据流前缀和目录形式路径。
`allow_parent_paths=true` 允许 `..`，并保留其操作系统解析顺序，避免越过符号链接时错误地
进行词法折叠。原始名称始终保留。加载器签名为 `(Bytes, Int) -> Result[Bytes, String]`，
直接文件请求接收路径和声明大小；容器请求接收路径和剩余容器字节预算。
库在调用前检查预算，调用后检查长度。嵌套 thin 的子路径相对于该 thin 容器目录解析。

实际根目录、链接解析和读取内存由加载器负责。`materialize` 的 64 MiB 默认预算是所有
外部成员累计数据预算，含重复引用；单次 `load_member` 的预算只约束该成员。
存在索引时，物化必须显式同意丢弃，再由新 Builder 重新发现或指定符号。

## 外部成员校验与比较快照

`thin.validate_members(loader, max_bytes?, allow_parent_paths?, nested_limits?)` 校验全部外部引用，返回
实际加载的累计字节数。所有路径及累计声明大小在首次加载前检查；加载器失败返回 `AR013`，
实际长度不符返回 `AR014`，预算失败返回 `AR008`。此方法逐个检查，不保留已检查的数据。

`thin.snapshot(loader, max_bytes?, allow_parent_paths?)` 返回不可变 `ArchiveSnapshot`，
保存加载所得的成员内容。普通归档使用 `archive.snapshot()`，无需加载器。
两种快照通过 `before.compare_logical(after)` 直接比较，返回现有 `LogicalComparison`。

比较保留原索引映射与原始物理成员位置，不重新发现对象符号，不写出中间归档。
`bytes_equal` 比较原容器；`content_equal` 比较实际加载的普通成员。因此 thin 容器完全相同，
仍可能得到 `bytes_equal=true`、`content_equal=false`。相同名称的符号目标顺序仍参与比较。

快照建立后无需再次访问文件。加载期间的多文件读取不是原子事务，应由调用方控制并发写入。
thin 容器不保存外部文件的历史内容；需要跨时间比较时，应分别在两个时间点捕获快照。
直接引用名称按原始路径字节比较；嵌套引用使用最终成员的逻辑名称，保留外层 thin 元数据。

CLI 使用 `check FILE --external` 检查外部成员，用 `diff BEFORE AFTER --logical`
直接比较普通/thin 的任意组合。默认真实路径根目录检查及 `--allow-parent-paths` 与编辑流程一致。
`check --external` 的外部加载失败退出 1，逻辑比较的输入/加载失败退出 2。

## thin 创建与编辑

`ThinWriteMember::new(name, size, metadata?, archive_member_offset?)` 描述外部引用。
`archive_member_offset=None` 引用整个文件，`Some(offset)` 引用所命名归档中的成员头部。
`ThinArchiveBuilder::from_members` 批量创建计划，亦提供 `new`、`append`、`insert`、
`replace`、`remove`、`move_member`、`members`、`member_count`。
`thin.edit(drop_symbol_indexes=true)` 导入普通外部成员。

```moonbit
let plan = @ar.ThinArchiveBuilder::from_members([
  @ar.ThinWriteMember::new(b"obj/first.o", 128),
]).unwrap()
let bytes = plan.write(symbol_width=64).unwrap()
```

这里的 `128` 必须对应外部文件真实长度。写出器不访问文件系统，接受调用方提供的符号映射，
`symbol_width` 为 32 或 64；GNU 名称表、符号引用和成员头偏移自动计算。
thin 文件不包含对象载荷。自动发现需先加载对象；CLI 已实现此流程。
CLI 创建或追加 thin 时，普通归档输入展开为 archive-offset 引用，thin 输入展开已有引用；
不把整个归档当成对象。输入 thin 的引用路径按目标目录重新计算。

## 文件级行为

CLI 默认从最终对象集合发现符号，每次编辑后重建索引；`--index none` 显式跳过符号发现，
thin 普通编辑可不加载已有直接成员，新输入及物化仍需读取。嵌套引用的输出保护会遍历
所需容器元数据，禁止输出覆盖传递依赖；删除损坏引用的原位编辑仍可执行。提取读取选定成员。
thin 的缺失成员可以先删除再重建。
宿主路径与成员名称分别处理：Windows 文件参数接受反斜杠与盘符相对形式，保留根目录
含义；POSIX 文件参数保留字面反斜杠。`rename` 的成员名称不进行宿主路径转换。
`rename` 对 thin 表示改变外部引用，自动模式会加载新目标并核对长度。
另存到新目录时会基于真实路径重定位引用。`convert` 将 thin 物化为普通归档。

文件写入采用同目录临时文件及原子发布；新建默认禁止覆盖，`--force` 明确允许替换，原位编辑
允许替换。所有加载、索引与布局检查在发布前完成。native 与 Node.js 实现实际文件写入；
wasm/wasm-gc 使用库接口并由宿主提供加载器。路径检查与打开不是单一文件系统事务，使用者
应控制构建目录的并发修改。

## 预算与错误

解析及写出接受五项预算：字节、物理记录、展开成员名称、符号数、展开符号名称。
默认值见 README。thin 的容器预算与外部加载预算分别计算；CLI 外部数据使用累计字节预算。
写出缓冲区在布局检查完成后分配，大小和偏移上限为有符号 32 位整数。

所有 thin 加载接口另接受 `nested_limits=NestedLimits::new(...)`。默认最多读取 64 MiB
嵌套容器、100000 条容器记录、64 MiB 名称、1000000 个符号和 64 MiB 符号名，深度 16。
同路径容器在单次批量操作中只计费、读取及解析一次；已解析成员名称与唯一依赖路径共享
名称预算。深度最大可设 64，循环引用直接报错。直接成员仍按每次引用累计载荷。
已计费的依赖路径可在剩余名称预算为零时继续使用；新路径超过剩余预算则在加载前返回 `AR008`。
CLI 用 `--max-archive-bytes`、`--max-depth` 调整容器字节与深度，其余预算沿用对应选项。

| 代码 | 含义 |
| --- | --- |
| `AR011` | 不支持的 thin 引用或非外部成员 |
| `AR012` | 外部路径不符合加载策略 |
| `AR013` | 加载器失败 |
| `AR014` | 实际长度与声明大小不一致 |
| `AR015` | 嵌套偏移未指向普通成员或出现循环引用 |
| `AR008` | 解析/加载预算错误 |
| `WR001` | 成员名称或位置非法 |
| `WR002` | 元数据无法写入头部 |
| `WR003` | 写出/发现预算错误 |
| `WR004` | 导入索引需要显式处理策略 |
| `WR005` | 符号名称、目标或索引请求非法 |
| `WR006` | 成员对象不支持或损坏，消息含对象诊断 |
| `OB001` / `OB002` / `OB003` | 单对象结构错误 / 不支持 / 预算错误 |

更多字段见 [API](API.md)，独立工具与实际消费者见 [复现指南](REVIEW.md)。
