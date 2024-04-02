# AWS SDK for Zig

The _AWS SDK for Zig_ provides an interface for _Amazon Web Services (AWS)_.
It builds upon Zig’s strong capabilities to provide a performant and fully
functioning SDKs, while minimizing dependencies and providing platform portability.

> [!TIP]
> Use the [AWS Lambda Runtime for Zig](https://github.com/by-nir/aws-lambda-zig)
> to deploy _Lambda_ functions written in Zig.

## Contributing

| 📁 | Public | CodeGen | Description |
|:-|:-:|:-:|:-|
| [src/types](src/types) | ✅ | | Common types shared by _AWS for Zig_ modules. |
| [src/runtime](src/runtime) | | | Client for interacting with _AWS_ services. |

## License

> [!NOTE]
> _AWS SDK for Zig_ is not an official _Amazon Web Services_ software, nor is it
> affiliated with _Amazon Web Services, Inc_.

The author and contributors are not responsible for any issues or damages caused
by the use of this software, part of it, or its derivatives. See [LICENSE](/LICENSE)
for the complete terms of use.

### Acknowledgment

- [Smithy Rust](https://github.com/smithy-lang/smithy-rs)
- [AWS SDK for Rust](https://github.com/awslabs/aws-sdk-rust)
- [AWS SDK for C++](https://github.com/aws/aws-sdk-cpp)
- [AWS Common Runtime (CRT) libraries](https://docs.aws.amazon.com/sdkref/latest/guide/common-runtime.html)