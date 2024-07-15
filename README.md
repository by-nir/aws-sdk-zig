# AWS SDK for Zig

![Zig v0.14 (dev)](https://img.shields.io/badge/Zig-v0.14_(dev)_-black?logo=zig&logoColor=F7A41D "Zig v0.14 – master branch")
[![MIT License](https://img.shields.io/github/license/by-nir/aws-sdk-zig)](/LICENSE)

**The _AWS SDK for Zig_ provides an interface for _Amazon Web Services (AWS)_.**

> [!CAUTION]
> This project is in early development, DO NOT USE IN PRODUCTION!
>
> Support for the remaining services and features will be added as the project
> matures and stabilize. Till then, **breaking changes are imminent!**.

_Pure Zig implementation,_ from code generation to runtime SDKs.
Building upon the language’s strong foundation, this project provides a
**performant** and fully functioning SDKs, while **minimizing dependencies** and
increased **platform portability**.

> [!TIP]
> Use the [AWS Lambda Runtime for Zig](https://github.com/by-nir/aws-lambda-zig)
> to deploy Lambda functions written in Zig.

## Contributing

| 📁 | Description |
|:-|:-|
| [sdk](sdk/) | AWS SDKs for Zig |
| [aws/runtime](aws/runtime/) | SDK Runtime, shared by all the services _AWS SDKs_ |
| [aws/codegen](aws/codegen/) | AWS-specific source generation pipeline |
| [smithy/runtime](smithy/runtime/) | [Smithy 2.0](https://smithy.io/2.0) client runtime |
| [smithy/src](smithy/src/) | [Smithy 2.0](https://smithy.io/2.0) source generation pipeline |

### CLI Commands

- `zig build --build-file build.codegen.zig` Generate the AWS SDKs source code.
    - Optionally specify one or more `-Dfilter=sdk_codename` to select specific services.
- `zig build test:<service>` Run generated SDK service’s unit tests.

## License

The author and contributors are not responsible for any issues or damages caused
by the use of this software, part of it, or its derivatives. See [LICENSE](/LICENSE)
for the complete terms of use.

> [!NOTE]
> _AWS SDK for Zig_ is not an official _Amazon Web Services_ software, nor is it
> affiliated with _Amazon Web Services, Inc_.

The SDKs code is generated based on a dataset of _Smithy models_ created by
_Amazon Web Services_. The models are extracted from the official [AWS SDK for Rust](https://github.com/awslabs/aws-sdk-rust)
and [licensed](https://github.com/awslabs/aws-sdk-rust/blob/main/LICENSE) as 
declared by Amazon Web Services, Inc. at the source repository.
This codebase, including the generated code, are covered by a [standalone license](/LICENSE).

## References

### Smithy

- [Smithy Spec](https://smithy.io/2.0/index.html)
- [Smithy Reference Implementation](https://github.com/smithy-lang/smithy)
- [Smithy Rust](https://github.com/smithy-lang/smithy-rs)

### AWS SDKs

- [AWS SDKs and Tools Reference Guide](https://docs.aws.amazon.com/sdkref/latest/guide/overview.html)
- [AWS Common Runtime (CRT) libraries](https://docs.aws.amazon.com/sdkref/latest/guide/common-runtime.html)
- [AWS SDK for C++](https://github.com/aws/aws-sdk-cpp)
- [AWS SDK for Rust](https://github.com/awslabs/aws-sdk-rust)