# AWS SDK for Zig
![Zig v0.12 (master)](https://img.shields.io/badge/Zig-v0.12_(master)-black?logo=zig&logoColor=F7A41D)
[![MIT License](https://img.shields.io/github/license/by-nir/aws-sdk-zig)](/LICENSE)

The _AWS SDK for Zig_ provides an interface for _Amazon Web Services (AWS)_.
It builds upon Zig’s strong capabilities to provide a performant and fully
functioning SDKs, while minimizing dependencies and providing platform portability.

> [!TIP]
> Use the [AWS Lambda Runtime for Zig](https://github.com/by-nir/aws-lambda-zig)
> to deploy _Lambda_ functions written in Zig.

## Getting Started

> [!CAUTION]
> This project is in early development, **breaking changes are imminent!**

## Contributing

Parts of this codebase are auto-generated, **do not modify them directly!**

Generate the source code run `zig build sdk --build-file build.codegen.zig`.
Optionally specify one or more `-Dfilter=sdk_codename` to generate specific services.

Run unit tests for codegen run `zig build test --build-file build.codegen.zig`

| 📁 | Public | CodeGen | Description |
|:-|:-:|:-:|:-|
| [src/runtime](src/runtime) | | | Shared client for interacting with _AWS_ services. |
| [src/types](src/types) | ✅ | | Common types shared by all modules. |
| [codegen](codegen) | ✅ | | Automation workflows for code generation. |
| [sdk](sdk) | ✅ | ✅ | AWS SDKs for Zig. |

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

### AWS SDKs Resources

https://smithy.io/2.0/index.html
https://docs.aws.amazon.com/sdkref/latest/guide/overview.html

### Other Implementations

- [Smithy Rust](https://github.com/smithy-lang/smithy-rs)
- [AWS SDK for Rust](https://github.com/awslabs/aws-sdk-rust)
- [AWS SDK for C++](https://github.com/aws/aws-sdk-cpp)
- [AWS Common Runtime (CRT) libraries](https://docs.aws.amazon.com/sdkref/latest/guide/common-runtime.html)