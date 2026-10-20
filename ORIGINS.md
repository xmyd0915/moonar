# 来源与实现说明

MoonAr 使用 [MIT 许可证](LICENSE)。解析与比较代码依据公开格式资料独立实现，
未复制其他归档解析器的实现代码。MoonBit 初始化工具生成了项目指引和 Git hook 模板。

## 格式与行为参考

- [GNU ar 文档](https://sourceware.org/binutils/docs/binutils/ar.html)：
  归档命令、确定性模式、重复成员和符号索引的行为。
- [LLVM ar 文档](https://llvm.org/docs/CommandGuide/llvm-ar.html)：
  GNU、BSD、Darwin 格式，以及成员列举、提取和确定性模式。
- [LLVM 18.1.3 ArchiveWriter.cpp](https://github.com/llvm/llvm-project/blob/llvmorg-18.1.3/llvm/lib/Object/ArchiveWriter.cpp)：
  GNU/BSD 32/64 位索引布局、Darwin 对齐与重名时间戳行为，以及 `SYM64_THRESHOLD`
  小文件验证开关；未复制其实现代码。
- [LLVM 18.1.3 Archive.cpp](https://github.com/llvm/llvm-project/blob/llvmorg-18.1.3/llvm/lib/Object/Archive.cpp)：
  GNU 长名称表按首个换行识别结束并检查前置斜杠的互操作约束。
- [Debian deb(5)](https://manpages.debian.org/bookworm/dpkg-dev/deb.5.en.html)：
  `.deb` 外层 ar 成员与 `debian-binary` 版本标记。
- [MoonBit 包文档](https://docs.moonbitlang.com/en/latest/language/packages.html)：
  包与类型的访问控制，用于封装 `Archive` 的内部存储。
- [System V ELF ABI](https://gabi.xinuos.com/elf/contents.html)：ELF 头部、节与符号表。
- [LLVM MachO.h](https://github.com/llvm/llvm-project/blob/llvmorg-18.1.3/llvm/include/llvm/BinaryFormat/MachO.h)：
  Mach-O 对象、加载命令与符号标志的格式定义。
- [Microsoft PE/COFF 格式](https://learn.microsoft.com/en-us/windows/win32/debug/pe-format)：
  COFF 对象头、节、符号、字符串及辅助记录。

实现所覆盖的格式和限制见 [README](README.md)。

## 依赖与验证工具

- [moonbitlang/core](https://github.com/moonbitlang/core)：Apache-2.0，提供核心库接口。
- [moonbitlang/x](https://github.com/moonbitlang/x)，版本 `0.5.5`：Apache-2.0，
  CLI 和文件读取示例使用其文件系统及进程接口。解析库不导入该依赖。

以上依赖由 MoonBit 工具链解析，不将依赖源码复制进本仓库。
GNU binutils、LLVM 和 Python 作为独立验证程序运行，源码和二进制均不随项目分发。
CI 使用固定提交的 GitHub Actions 和固定版本的 MoonBit 工具链。

## 示例与测试数据

`examples/data/` 中的文件由 [tools/examples.py](tools/examples.py) 从本项目编写的
简短数据生成。`.a` 示例包含文本与二进制数据；截断归档用于验证错误处理。
Debian 示例只包含一个控制文件和一个问候文本文件，没有安装脚本。

[tools/verify_archives.py](tools/verify_archives.py) 中的 C 函数和其他输入也由本项目编写，
运行时在临时目录编译并生成归档，用于与 GNU/LLVM 的输出比较。

这些示例和验证脚本使用本仓库的 MIT 许可证，未包含外部 SDK 或第三方软件包内容。

`tools/verify_zlib.py` 使用 [zlib 1.3.1 官方源码](https://zlib.net/fossils/zlib-1.3.1.tar.gz)
作为真实构建消费者，SHA-256 固定为
`9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23`。
脚本在临时目录下载、核对、解压与编译；也接受同摘要的本地缓存。zlib 源码采用上游
zlib 许可证，其原始版权和许可文件保留在临时源码目录，不随 MoonAr 发布包分发。
此版本作为固定的兼容性样本使用。
