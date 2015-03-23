# Flume backend for lager

This backend is implemented for lager users to log messages to flume. 
This library works with flume 1.6+ only, since thrift erlang library does not have compact protocol support,
while thrift binary protocol was added to flume since 1.6.

## Usage

Lager handler config should be 
```
{lager_flume_backend, ["localhost", 4141, info]}
```
while flume thrift source might look like
```
# thrift source
a1.sources.r1.type = thrift
a1.sources.r1.channels = c1
a1.sources.r1.bind = 0.0.0.0
a1.sources.r1.port = 4141
a1.sources.r1.protocol = binary
```

## Notes

The backend would:

1. not start when incorrect configuration found, and 
2. reconnect regularly when something wrong happens with connections to flume, e.g. flume agent exit, 
in which case, log messages will be discarded temporarily.
