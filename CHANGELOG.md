# Changelog

This changelog follows the [keep a changelog](https://keepachangelog.com/en/1.1.0/)
format. This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Add `ReqCircuitBreaker.install/2`, `ReqCircuitBreaker.installed?/1`,
  `ReqCircuitBreaker.remove/1` and `ReqCircuitBreaker.reset/1`
  for managing a circuit breaker.
- Add `ReqCircuitBreaker.ask/2` for checking a circuit.
- Add `ReqCircuitBreaker.record_failure/1` for recording a failure.
- Add `ReqCircuitBreaker.run/3` for running any function under a circuit
  breaker.
- Add `ReqCircuitBreaker.attach/2` for protecting a `Req` request.
- Add `ReqCircuitBreaker.failure?/1`, the default function for deciding whether
  a response or exception counts as a failure of the service.

[Unreleased]: https://github.com/scoville/req_circuit_breaker/commits/main
