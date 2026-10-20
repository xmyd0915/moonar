# 归档创建与成员处理示例

本示例直接使用 MoonAr 公共接口，不调用外部归档工具。
从仓库根目录运行；输出路径应选用用于示例的新文件。

## 创建和编辑普通归档

```sh
moon run examples/archive_workflow --target native -- create output.a gnu
moon run examples/archive_workflow --target native -- create output-bsd.a bsd
moon run examples/archive_workflow --target native -- edit output.a edited.a
```

创建结果包含文本、三字节二进制、两个内容不同的 `same.txt` 和一个空成员。
编辑流程追加 `added.txt`，替换首项内容，删除长名称项，并把第二个同名成员移到开头。
最终成员依次为：

| 名称 | 数据 |
| --- | --- |
| same.txt | second |
| short.txt | updated |
| same.txt | first |
| empty | 空字节 |
| added.txt | appended |

源归档不变，结果写到独立文件。这个示例拒绝隐式丢弃源归档的符号索引。

## 加载 thin 成员并转成普通归档

给定参考工具生成的 `input-thin.a`，包含 `one.o` 和 `sub/two.o`：

```sh
moon run examples/archive_workflow --target native -- thin input-thin.a one.o one.o sub/two.o sub/two.o
moon run examples/archive_workflow --target native -- materialize input-thin.a regular.a one.o one.o sub/two.o sub/two.o
```

归档路径后是成对的“成员路径、实际输入文件”。示例先读取明确给出的文件，
再通过名称映射提供字节；归档内的路径不会直接触发磁盘读取。缺失映射和大小不符均失败。
输出 JSON 包含名称十六进制、实际大小和输入符号数量。

`materialize` 展示数据成员的物化，生成不含索引的普通 GNU 归档。
需要用于链接时，可在最终写出时传入新的符号映射。

## 写出可链接静态库

`indexed` 接收分别定义 `moon_alpha` 和 `moon_beta` 的两个对象文件，
为最终成员序列提供显式符号映射：

```sh
moon run examples/archive_workflow --target native -- indexed library.a alpha.o beta.o
moon run examples/archive_workflow --target native -- reindex library.a edited-library.a replacement-alpha.o
```

这些函数名是本示例约定，通用库接受任意有效的调用方符号映射。
`reindex` 替换第一个对象、交换两个成员的顺序，并按最终位置重新提供符号映射。
自动验收脚本生成对象文件、检查映射、链接并运行程序：

```sh
moon build --target native --deny-warn
python tools/verify_workflow.py --workflow _build/native/debug/build/examples/archive_workflow/archive_workflow.exe --require-llvm
```

需要 GNU ar/nm、gcc/cc 和 LLVM ar。脚本还覆盖确定性字节、GNU/BSD 提取、重名编辑、
参考工具 thin 输入、加载失败和物化结果。对象替换后再次链接运行，核对函数结果发生预期变化。
