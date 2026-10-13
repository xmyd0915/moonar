# 复现指南

这份指南用于快速核对 MoonAr 的功能、输出与边界。命令均从仓库根目录运行。
环境要求见 [README](../README.md#快速开始)；自动核对脚本需要 Python 3.9+。

## 运行三个场景

先构建 CLI，再执行示例核对和公共 API 消费者：

```sh
moon update
moon build --target native --deny-warn
python tools/examples.py --moonar _build/native/debug/build/cmd/main/main.exe
moon run examples/read_deb --target native
```

示例核对脚本依次验证：

| 检查 | 预期结果 |
| --- | --- |
| 读取 `bundle-before.a` | `config.txt` 为 11 字节，`assets.bin` 为 3 字节 |
| 检查 `bundle-broken.a` | 退出码 1，错误 `AR002`，偏移 140 |
| 与 `bundle-time.a` 比较 | 两个成员均只有元数据变化；退出码 1 |
| 与 `bundle-content.a` 比较 | 只有 `config.txt` 内容变化；退出码 1 |
| 读取 `demo.deb` | 找到 `debian-binary`、`control.tar.gz` 和 `data.tar.gz` |

`read_deb` 示例另外通过库接口取得成员数据，并核对 `debian-binary` 的 `2.0` 标记。
需要逐条手动运行时，参照 [完整场景说明](../examples/README.md)。

## 核对测试与独立工具结果

```sh
moon fmt --check
moon check --target all --deny-warn
moon test --target all --deny-warn
```

`--target all` 会让同一组测试分别运行在 wasm、wasm-gc、JavaScript 和 native 上。
GNU/LLVM 对照需要额外安装 GNU ar、LLVM ar 和 gcc/cc：

```sh
python tools/verify_archives.py --moonar _build/native/debug/build/cmd/main/main.exe --require-llvm
```

脚本会生成自己的输入，比较成员列表和实际提取字节，并检查真实对象文件变化。
可在 [CI 工作流](../.github/workflows/ci.yml) 查看完整环境与步骤，在
[Actions](https://github.com/xmyd0915/moonar/actions) 查看对应提交的 Linux、Windows 结果。

## 阅读代码

建议依次阅读 [类型与访问接口](../types.mbt)、[解析入口](../parse.mbt)、
[名称处理](../names.mbt)、[归档比较](../compare.mbt)，再看
[公共 API 示例](../examples/read_deb/main.mbt)。

重点核对以下边界：

- 解析失败返回错误代码和偏移，不静默跳过坏记录。
- 文件名不保证是 UTF-8；十六进制名称保留原始字节，显示名称可能有替换字符。
- 重名项按出现次序配对；插入新的同名项可能改变后续配对。
- BSD 名称字节与成员数据分开；Darwin 声明在数据大小内的填充保留。
- `check` 通过表示受支持的容器结构可读，不代表对象可链接、符号索引或包签名有效。
- CLI 在解析限制生效前读取完整文件；库和 CLI 都不提供流式读取。

JSON 字段与错误代码见 [API 说明](API.md)，格式与依赖来源见 [ORIGINS.md](../ORIGINS.md)。
