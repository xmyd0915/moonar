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

`WriteFormat` 包含 `Gnu`、`Gnu64`、`Bsd`、`Bsd64`、`Darwin`、`Darwin64`。
默认 `metadata=Deterministic` 写时间戳、UID、GID 为零，模式为 `0644`。
`metadata=Preserve` 保留输入字段，空字段写空格；数值必须非负且能装入字段。
Darwin 遵循八字节对齐，并为确定性重名成员分配递增时间戳。

名称不能为空或含 NUL。GNU 长名称不能含换行；与特殊记录同名的普通文件通过长名称表
表达。BSD/Darwin 拒绝这些保留名称，可保存其他包含换行的名称。名称无需为 UTF-8。
Darwin 计入载荷的填充会在读取及提取时保留。

## 显式映射与自动发现

`write(symbols=Some(mappings))` 写出索引，每个 `WriteSymbol` 含 `name : Bytes` 和最终
普通成员序号 `member_index : Int`。索引偏移由最终布局计算，调用方不必计算文件偏移。
GNU 使用大端；BSD/Darwin 使用 `index_little_endian` 选择字节序，默认为 `true`。
`None` 不生成索引，`Some([])` 生成空索引；Darwin 始终包含至少一个空索引。

```moonbit
let symbols = plan.discover_symbols().unwrap()
let bytes = plan.write(format=@ar.Gnu64, symbols=Some(symbols)).unwrap()
```

`ArchiveBuilder::discover_symbols` 扫描最终成员，返回映射；单个对象可调用
`symbols_from_object(bytes)`。支持：

- ELF32/64，大小端，可重定位对象；全局、弱、公共、绝对、GNU unique 定义和扩展节号。
- Mach-O32/64，大小端，`MH_OBJECT` 的符号表；外部定义、弱/公共/绝对及可索引别名。
- 标准小端 COFF 对象，包括辅助记录、长名称和可解析的弱别名；不把 BSS 虚拟大小当作文件数据。

排除未定义、局部及不适合归档索引的记录；同一对象内重复名称按首次出现去重，跨成员同名
符号保持顺序。非对象数据返回空符号数组；已识别的损坏对象返回 `OB001`，不支持的对象
布局返回 `OB002`。bigobj、import object、PE、LTO/bitcode、fat Mach-O、wasm 和归档容器
不作为普通可索引对象处理。不能将不支持的已识别对象静默当成空符号对象。

`max_symbols` 默认 1,000,000，按扫描记录计费，包括被过滤的符号；
`max_symbol_name_bytes` 默认 64 MiB，按展开名称计费。Builder 在全部成员间共享预算，
避免每个对象各用一份上限。对象失败转为含成员位置的 `WR006`，预算失败转为 `WR003`。

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

外部成员的声明大小不占据容器字节，也不导致容器奇数补齐。名称表与索引仍内嵌。
支持直接文件引用；GNU `/name-offset:archive-offset` 嵌套引用和 BSD 内嵌名称返回 `AR011`。

默认路径策略拒绝绝对路径、父目录、反斜杠、驱动器/数据流前缀和目录形式路径。
`allow_parent_paths=true` 允许 `..`，并保留其操作系统解析顺序，避免越过符号链接时错误地
进行词法折叠。原始名称始终保留。加载器签名为 `(Bytes, Int) -> Result[Bytes, String]`，
接收路径和声明大小；库在调用前检查预算，调用后检查长度。

实际根目录、链接解析和读取内存由加载器负责。`materialize` 的 64 MiB 默认预算是所有
外部成员累计数据预算，含重复引用；单次 `load_member` 的预算只约束该成员。
存在索引时，物化必须显式同意丢弃，再由新 Builder 重新发现或指定符号。

## thin 创建与编辑

`ThinWriteMember::new(name, size, metadata?)` 描述外部文件引用。
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

## 文件级行为

CLI 默认从最终对象集合发现符号，每次编辑后重建索引；`--index none` 显式跳过符号发现，
thin 普通编辑可不加载已有成员，新输入及物化仍需读取。提取始终读取选定成员。
thin 的缺失成员可以先删除再重建。
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

| 代码 | 含义 |
| --- | --- |
| `AR011` | 不支持的 thin 引用或非外部成员 |
| `AR012` | 外部路径不符合加载策略 |
| `AR013` | 加载器失败 |
| `AR014` | 实际长度与声明大小不一致 |
| `AR008` | 解析/加载预算错误 |
| `WR001` | 成员名称或位置非法 |
| `WR002` | 元数据无法写入头部 |
| `WR003` | 写出/发现预算错误 |
| `WR004` | 导入索引需要显式处理策略 |
| `WR005` | 符号名称、目标或索引请求非法 |
| `WR006` | 成员对象不支持或损坏，消息含对象诊断 |
| `OB001` / `OB002` / `OB003` | 单对象结构错误 / 不支持 / 预算错误 |

更多字段见 [API](API.md)，独立工具与实际消费者见 [复现指南](REVIEW.md)。
