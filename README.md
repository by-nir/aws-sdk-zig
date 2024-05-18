# AWS SDK for Zig
![Zig v0.13 (dev)](https://img.shields.io/badge/Zig-v0.13_(dev)_-black?logo=zig&logoColor=F7A41D "Zig v0.13 – master branch")
[![MIT License](https://img.shields.io/github/license/by-nir/aws-sdk-zig)](/LICENSE)

**The _AWS SDK for Zig_ provides an interface for _Amazon Web Services (AWS)_.**

_Pure Zig implementation,_ from code generation to runtime SDKs.
Building upon the language’s strong foundation, this project provides a
**performant** and fully functioning SDKs, while **minimizing dependencies** and
increased **platform portability**.

> [!TIP]
> Use the [AWS Lambda Runtime for Zig](https://github.com/by-nir/aws-lambda-zig)
> to deploy Lambda functions written in Zig.

## Getting Started

> [!CAUTION]
> This project is in early development, DO NOT USE IN PRODUCTION!
>
> Support for the remaining services and features will be added as the project
> matures and stabilize. Till then, **breaking changes are imminent!**.

## Contributing

Parts of this codebase are auto-generated, **do not modify them directly!**

| 📁 | 👁️[^1] | 🏭[^2] | Description |
|:-|:-:|:-:|:-|
| [sdk](sdk) | 👁️ | 🏭 | AWS SDKs for Zig |
| [src/types](src/types) | 👁️ | | Common types shared by all modules |
| [src/runtime](src/runtime) | | | Shared client for interacting with _AWS_ services |
| [codegen/aws](codegen) | | | SDKs source generation pipeline |
| [codegen/smithy](codegen/smithy) | | | [Smithy 2.0](https://smithy.io/2.0) client generator |

[^1]: Module exposed publicly
[^2]: Source auto-generated _(do not modify manyally)_

### CLI Commands

The source generation commands are available through the following CLI commands:
```zig build --build-file build.codegen.zig <command>```

- `aws` Generate the AWS SDKs source code.
    - Optionally specify one or more `-Dfilter=sdk_codename` to select specific services.
- `test:aws` Run unit tests for the AWS SDKs generation.
- `test:smithy` Run unit tests for the Smithy library.

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