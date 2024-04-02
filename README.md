# AWS SDK for Zig
![Zig v0.12 (master)](https://img.shields.io/badge/Zig-v0.12_(master)-black?logo=zig&logoColor=F7A41D)
[![MIT License](https://img.shields.io/github/license/by-nir/aws-sdk-zig)](https://github.com/by-nir/aws-sdk-zig/LICENSE)

The _AWS SDK for Zig_ provides an interface for _Amazon Web Services (AWS)_.
It builds upon Zig’s strong capabilities to provide a performant and fully
functioning SDKs, while minimizing dependencies and providing platform portability.

> [!CAUTION]
> This project is in early development, breaking changes are likely to occur!

> [!TIP]
> Use the [AWS Lambda Runtime for Zig](https://github.com/by-nir/aws-lambda-zig)
> to deploy _Lambda_ functions written in Zig.

## Contributing

| 📁 | Public | CodeGen | Description |
|:-|:-:|:-:|:-|
| [src/types](src/types) | ✅ | | Common types shared by _AWS for Zig_ modules. |
| [src/runtime](src/runtime) | | | Client for interacting with _AWS_ services. |

## License

The author and contributors are not responsible for any issues or damages caused
by the use of this software, part of it, or its derivatives. See [LICENSE](/LICENSE)
for the complete terms of use.

> [!NOTE]
> _AWS SDK for Zig_ is not an official _Amazon Web Services_ software, nor is it
> affiliated with _Amazon Web Services, Inc_.


### Acknowledgment

- [Smithy Rust](https://github.com/smithy-lang/smithy-rs)
- [AWS SDK for Rust](https://github.com/awslabs/aws-sdk-rust)
- [AWS SDK for C++](https://github.com/aws/aws-sdk-cpp)
- [AWS Common Runtime (CRT) libraries](https://docs.aws.amazon.com/sdkref/latest/guide/common-runtime.html)