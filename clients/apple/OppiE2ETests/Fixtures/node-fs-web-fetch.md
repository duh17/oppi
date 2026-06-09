# File system | Node.js v26.3.0 Documentation

[Source](https://nodejs.org/api/fs.html#fscreatereadstreampath-options) · nodejs.org · 36589 words · 386045 chars · direct

---

# File system | Node.js v26.3.0 Documentation

## File system#

**Source Code:**[lib/fs.js](https://github.com/nodejs/node/blob/main/lib/fs.js)
[Stability: 2](https://nodejs.org/api/documentation.html#stability-index) - Stable

The `node:fs` module enables interacting with the file system in a
way modeled on standard POSIX functions.

To use the promise-based APIs:

```mjs
import * as fs from 'node:fs/promises';
const fs = require('node:fs/promises');
javascriptcopy
```

To use the callback and sync APIs:

```mjs
import * as fs from 'node:fs';
const fs = require('node:fs');
javascriptcopy
```

All file system operations have synchronous, callback, and promise-based
forms, and are accessible using both CommonJS syntax and ES6 Modules (ESM).

### Promise example#

Promise-based operations return a promise that is fulfilled when the
asynchronous operation is complete.

```mjs
import { unlink } from 'node:fs/promises';

try {
  await unlink('/tmp/hello');
  console.log('successfully deleted /tmp/hello');
} catch (error) {
  console.error('there was an error:', error.message);
}
const { unlink } = require('node:fs/promises');

(async function(path) {
  try {
    await unlink(path);
    console.log(`successfully deleted ${path}`);
  } catch (error) {
    console.error('there was an error:', error.message);
  }
})('/tmp/hello');
javascriptcopy
```

### Callback example#

The callback form takes a completion callback function as its last
argument and invokes the operation asynchronously. The arguments passed to
the completion callback depend on the method, but the first argument is always
reserved for an exception. If the operation is completed successfully, then
the first argument is `null` or `undefined`.

```mjs
import { unlink } from 'node:fs';

unlink('/tmp/hello', (err) => {
  if (err) throw err;
  console.log('successfully deleted /tmp/hello');
});
const { unlink } = require('node:fs');

unlink('/tmp/hello', (err) => {
  if (err) throw err;
  console.log('successfully deleted /tmp/hello');
});
javascriptcopy
```

The callback-based versions of the `node:fs` module APIs are preferable over
the use of the promise APIs when maximal performance (both in terms of
execution time and memory allocation) is required.

### Synchronous example#

The synchronous APIs block the Node.js event loop and further JavaScript
execution until the operation is complete. Exceptions are thrown immediately
and can be handled using `try…catch`, or can be allowed to bubble up.

```mjs
import { unlinkSync } from 'node:fs';

try {
  unlinkSync('/tmp/hello');
  console.log('successfully deleted /tmp/hello');
} catch (err) {
  // handle the error
}
const { unlinkSync } = require('node:fs');

try {
  unlinkSync('/tmp/hello');
  console.log('successfully deleted /tmp/hello');
} catch (err) {
  // handle the error
}
javascriptcopy
```

### Promises API#

Added in: v10.0.0
**History**

| Version | Changes |
| --- | --- |
| v14.0.0 | Exposed as `require('fs/promises')`. |
| v11.14.0, v10.17.0 | This API is no longer experimental. |
| v10.1.0 | The API is accessible via `require('fs').promises` only. |

The `fs/promises` API provides asynchronous file system methods that return
promises.

The promise APIs use the underlying Node.js threadpool to perform file
system operations off the event loop thread. These operations are not
synchronized or threadsafe. Care must be taken when performing multiple
concurrent modifications on the same file or data corruption may occur.

#### Class: FileHandle#

Added in: v10.0.0
A [<FileHandle>](https://nodejs.org/api/fs.html#class-filehandle) object is an object wrapper for a numeric file descriptor.

Instances of the [<FileHandle>](https://nodejs.org/api/fs.html#class-filehandle) object are created by the`fsPromises.open()` method.

All [<FileHandle>](https://nodejs.org/api/fs.html#class-filehandle) objects are [<EventEmitter>](https://nodejs.org/api/events.html#class-eventemitter)s.

If a [<FileHandle>](https://nodejs.org/api/fs.html#class-filehandle) is not closed using the`filehandle.close()`method, it will
try to automatically close the file descriptor and emit a process warning,
helping to prevent memory leaks. Please do not rely on this behavior because
it can be unreliable and the file may not be closed. Instead, always explicitly
close [<FileHandle>](https://nodejs.org/api/fs.html#class-filehandle)s. Node.js may change this behavior in the future.

#### Event: 'close'#

Added in: v15.4.0
The `'close'`event is emitted when the [<FileHandle>](https://nodejs.org/api/fs.html#class-filehandle) has been closed and can no
longer be used.

#### filehandle.appendFile(data[, options])#

Added in: v10.0.0
**History**

| Version | Changes |
| --- | --- |
| v21.1.0, v20.10.0 | The `flush` option is now supported. |
| v15.14.0, v14.18.0 | The `data` argument supports `AsyncIterable`, `Iterable`, and `Stream`. |
| v14.0.0 | The `data` parameter won't coerce unsupported input to strings anymore. |

- `data`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<TypedArray>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/TypedArray) | [<DataView>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/DataView) | [<AsyncIterable>](https://tc39.github.io/ecma262/#sec-asynciterable-interface) | [<Stream>](https://nodejs.org/api/stream.html#stream)
- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object) | [<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type)
  - `encoding`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<null>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#null_type)**Default:**`'utf8'`
  - `signal`[<AbortSignal>](https://nodejs.org/api/globals.html#class-abortsignal) | [<undefined>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#undefined_type) allows aborting an in-progress writeFile.**Default:**`undefined`

- Returns: [<Promise>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Promise) Fulfills with`undefined` upon success.

Alias of [filehandle.writeFile()](#filehandlewritefiledata-options).

When operating on file handles, the mode cannot be changed from what it was set
to with [fsPromises.open()](#fspromisesopenpath-flags-mode). Therefore, this is equivalent to [filehandle.writeFile()](#filehandlewritefiledata-options).

#### filehandle.chmod(mode)#

Added in: v10.0.0
- `mode`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) the file mode bit mask.
- Returns: [<Promise>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Promise) Fulfills with`undefined` upon success.

Modifies the permissions on the file. See [chmod(2)](http://man7.org/linux/man-pages/man2/chmod.2.html).

#### filehandle.chown(uid, gid)#

Added in: v10.0.0
- `uid`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) The file's new owner's user id.
- `gid`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) The file's new group's group id.
- Returns: [<Promise>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Promise) Fulfills with`undefined` upon success.

Changes the ownership of the file. A wrapper for [chown(2)](http://man7.org/linux/man-pages/man2/chown.2.html).

#### filehandle.close()#

Added in: v10.0.0
- Returns: [<Promise>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Promise) Fulfills with`undefined` upon success.

Closes the file handle after waiting for any pending operation on the handle to
complete.

```mjs
import { open } from 'node:fs/promises';

let filehandle;
try {
  filehandle = await open('thefile.txt', 'r');
} finally {
  await filehandle?.close();
}
mjscopy
```

#### filehandle.createReadStream([options])#

Added in: v16.11.0
- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `encoding`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type)**Default:**`null`
  - `autoClose`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type)**Default:**`true`
  - `emitClose`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type)**Default:**`true`
  - `start`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
  - `end`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)**Default:**`Infinity`
  - `highWaterMark`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)**Default:**`64 * 1024`
  - `signal`[<AbortSignal>](https://nodejs.org/api/globals.html#class-abortsignal) | [<undefined>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#undefined_type)**Default:**`undefined`

- Returns: [<fs.ReadStream>](https://nodejs.org/api/fs.html#class-fsreadstream)

`options` can include `start` and `end` values to read a range of bytes from
the file instead of the entire file. Both `start` and `end` are inclusive and
start counting at 0, allowed values are in the
[0, [Number.MAX_SAFE_INTEGER](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Number/MAX_SAFE_INTEGER)] range. If `start` is
omitted or `undefined`, `filehandle.createReadStream()` reads sequentially from
the current file position. The `encoding`can be any one of those accepted by [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer).

If the `FileHandle` points to a character device that only supports blocking
reads (such as keyboard or sound card), read operations do not finish until data
is available. This can prevent the process from exiting and the stream from
closing naturally.

By default, the stream will emit a `'close'` event after it has been
destroyed. Set the `emitClose` option to `false` to change this behavior.

```mjs
import { open } from 'node:fs/promises';

const fd = await open('/dev/input/event0');
// Create a stream from some character device.
const stream = fd.createReadStream();
setTimeout(() => {
  stream.close(); // This may not close the stream.
  // Artificially marking end-of-stream, as if the underlying resource had
  // indicated end-of-file by itself, allows the stream to close.
  // This does not cancel pending read operations, and if there is such an
  // operation, the process may still not be able to exit successfully
  // until it finishes.
  stream.push(null);
  stream.read(0);
}, 100);
mjscopy
```

If `autoClose` is false, then the file descriptor won't be closed, even if
there's an error. It is the application's responsibility to close it and make
sure there's no file descriptor leak. If `autoClose` is set to true (default
behavior), on `'error'` or `'end'` the file descriptor will be closed
automatically.

An example to read the last 10 bytes of a file which is 100 bytes long:

```mjs
import { open } from 'node:fs/promises';

const fd = await open('sample.txt');
fd.createReadStream({ start: 90, end: 99 });
mjscopy
```

#### filehandle.createWriteStream([options])#

Added in: v16.11.0
**History**

| Version | Changes |
| --- | --- |
| v21.0.0, v20.10.0 | The `flush` option is now supported. |

- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `encoding`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type)**Default:**`'utf8'`
  - `autoClose`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type)**Default:**`true`
  - `emitClose`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type)**Default:**`true`
  - `start`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
  - `highWaterMark`[<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)**Default:**`16384`
  - `flush`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) If`true`, the underlying file descriptor is flushed
prior to closing it. **Default:**`false`.

- Returns: [<fs.WriteStream>](https://nodejs.org/api/fs.html#class-fswritestream)

`options` may also include a `start` option to allow writing data at some
position past the beginning of the file, allowed values are in the
[0, [Number.MAX_SAFE_INTEGER](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Number/MAX_SAFE_INTEGER)] range. Modifying a file rather than
replacing it may require the `flags``open` option to be set to `r+` rather than
the default `r`. The `encoding`can be any one of those accepted by [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer).

If `autoClose` is set to true (default behavior) on `'error'` or `'finish'` the file descriptor will be closed automatically. If `autoClose` is false,
then the file descriptor won't be closed, even if there's an error.
It is the application's responsibility to close it and make sure there's no
file descriptor leak.

By default, the stream will emit a `'close'` event after it has been
destroyed. Set the `emitClose` option to `false` to change this behavior.

#### filehandle.datasync()#

Added in: v10.0.0
- Returns: [<Promise>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Promise) Fulfills with`undefined` upon success.

Forces all currently queued I/O operations associated with the file to the
operating system's synchronized I/O completion state. Refer to the POSIX [fdatasync(2)](http://man7.org/linux/man-pages/man2/fdatasync.2.html) documentation for details.

Unlike `filehandle.sync` this method does not flush modified metadata.

#### filehandle.fd#

Added in: v10.0.0
- Type: [<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) The numeric file descriptor managed by the [<FileHandle>](https://nodejs.org/api/fs.html#class-filehandle) object.

#### filehandle.pull([...transforms][, options])#

Added in: v25.9.0
Stability: 1 - Experimental

- `...transforms`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function) | [<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object) Optional transforms to apply via[stream/iter pull()](https://nodejs.org/api/stream_iter.html#pullsource-transforms-options).
- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `signal`[<AbortSignal>](https://nodejs.org/api/globals.html#class-abortsignal)
  - `autoClose`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) Close the file handle when the stream ends.**Default:**`false`.
  - `start`[<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) Byte offset to begin reading from. When specified,
reads use explicit positioning (`pread` semantics). **Default:** current
file position.
  - `limit`[<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) Maximum number of bytes to read before ending the
iterator. Reads stop when`limit` bytes have been delivered or EOF is
reached, whichever comes first. **Default:** read until EOF.
  - `chunkSize`[<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) Size in bytes of the buffer allocated for each
read operation.**Default:**`131072` (128 KB).

- Returns: {AsyncIterable<Uint8Array[]>}

Return the file contents as an async iterable using the [node:stream/iter](https://nodejs.org/api/stream_iter.html) pull model. Reads are performed in `chunkSize`-byte
chunks (default 128 KB). If transforms are provided, they are applied
via [stream/iter pull()](https://nodejs.org/api/stream_iter.html#pullsource-transforms-options).

The file handle is locked while the iterable is being consumed and unlocked
when iteration completes, an error occurs, or the consumer breaks.

This function is only available when the `--experimental-stream-iter` flag is
enabled.

```mjs
import { open } from 'node:fs/promises';
import { text } from 'node:stream/iter';
import { compressGzip } from 'node:zlib/iter';

const fh = await open('input.txt', 'r');

// Read as text
console.log(await text(fh.pull({ autoClose: true })));

// Read 1 KB starting at byte 100
const fh2 = await open('input.txt', 'r');
console.log(await text(fh2.pull({ start: 100, limit: 1024, autoClose: true })));

// Read with compression
const fh3 = await open('input.txt', 'r');
const compressed = fh3.pull(compressGzip(), { autoClose: true });
const { open } = require('node:fs/promises');
const { text } = require('node:stream/iter');
const { compressGzip } = require('node:zlib/iter');

async function run() {
  const fh = await open('input.txt', 'r');

  // Read as text
  console.log(await text(fh.pull({ autoClose: true })));

  // Read 1 KB starting at byte 100
  const fh2 = await open('input.txt', 'r');
  console.log(await text(fh2.pull({ start: 100, limit: 1024, autoClose: true })));

  // Read with compression
  const fh3 = await open('input.txt', 'r');
  const compressed = fh3.pull(compressGzip(), { autoClose: true });
}

run().catch(console.error);
javascriptcopy
```

#### filehandle.pullSync([...transforms][, options])#

Added in: v25.9.0
Stability: 1 - Experimental

- `...transforms`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function) | [<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object) Optional transforms to apply via[stream/iter pullSync()](https://nodejs.org/api/stream_iter.html#pullsyncsource-transforms).
- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `autoClose`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) Close the file handle when the stream ends.**Default:**`false`.
  - `start`[<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) Byte offset to begin reading from. When specified,
reads use explicit positioning.**Default:** current file position.
  - `limit`[<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) Maximum number of bytes to read before ending the
iterator.**Default:** read until EOF.
  - `chunkSize`[<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) Size in bytes of the buffer allocated for each
read operation.**Default:**`131072` (128 KB).

- Returns: {Iterable<Uint8Array[]>}

Synchronous counterpart of [filehandle.pull()](#filehandlepulltransforms-options). Returns a sync iterable
that reads the file using synchronous I/O on the main thread. Reads are
performed in `chunkSize`-byte chunks (default 128 KB).

The file handle is locked while the iterable is being consumed. Unlike the
async `pull()`, this method does not support `AbortSignal` since all
operations are synchronous.

This function is only available when the `--experimental-stream-iter` flag is
enabled.

```mjs
import { open } from 'node:fs/promises';
import { textSync, pipeToSync } from 'node:stream/iter';
import { compressGzipSync, decompressGzipSync } from 'node:zlib/iter';

const fh = await open('input.txt', 'r');

// Read as text (sync)
console.log(textSync(fh.pullSync({ autoClose: true })));

// Sync compress pipeline: file -> gzip -> file
const src = await open('input.txt', 'r');
const dst = await open('output.gz', 'w');
pipeToSync(src.pullSync(compressGzipSync(), { autoClose: true }), dst.writer({ autoClose: true }));
const { open } = require('node:fs/promises');
const { textSync, pipeToSync } = require('node:stream/iter');
const { compressGzipSync, decompressGzipSync } = require('node:zlib/iter');

async function run() {
  const fh = await open('input.txt', 'r');

  // Read as text (sync)
  console.log(textSync(fh.pullSync({ autoClose: true })));

  // Sync compress pipeline: file -> gzip -> file
  const src = await open('input.txt', 'r');
  const dst = await open('output.gz', 'w');
  pipeToSync(
    src.pullSync(compressGzipSync(), { autoClose: true }),
    dst.writer({ autoClose: true }),
  );
}

run().catch(console.error);
javascriptcopy
```

#### filehandle.read(buffer, offset, length, position)#

Added in: v10.0.0
**History**

| Version | Changes |
| --- | --- |
| v21.0.0 | Accepts bigint values as `position`. |

- `buffer`[<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<TypedArray>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/TypedArray) | [<DataView>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/DataView) A buffer that will be filled with the
file data read.
- `offset`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) The location in the buffer at which to start filling.**Default:**`0`
- `length`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) The number of bytes to read.**Default:**`buffer.byteLength - offset`
- `position`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<bigint>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#bigint_type) | [<null>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#null_type) The location where to begin reading data
from the file. If`null` or `-1`, data will be read from the current file
position, and the position will be updated. If `position` is a non-negative
integer, the current file position will remain unchanged. **Default:**`null`
- Returns: [<Promise>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Promise) Fulfills upon success with an object with two properties:
  - `bytesRead`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) The number of bytes read
  - `buffer`[<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<TypedArray>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/TypedArray) | [<DataView>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/DataView) A reference to the passed in`buffer` argument.

Reads data from the file and stores that in the given buffer.

If the file is not modified concurrently, the end-of-file is reached when the
number of bytes read is zero.

#### filehandle.read([options])#

Added in: v13.11.0, v12.17.0
**History**

| Version | Changes |
| --- | --- |
| v21.0.0 | Accepts bigint values as `position`. |

- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `buffer`[<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<TypedArray>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/TypedArray) | [<DataView>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/DataView) A buffer that will be filled with the
file data read.**Default:**`Buffer.alloc(16384)`
  - `offset`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) The location in the buffer at which to start filling.**Default:**`0`
  - `length`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) The number of bytes to read.**Default:**`buffer.byteLength - offset`
  - `position`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<bigint>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#bigint_type) | [<null>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#null_type) The location where to begin reading data
from the file. If`null` or `-1`, data will be read from the current file
position, and the position will be updated. If `position` is a non-negative
integer, the current file position will remain unchanged. **Default:**: `null`

- Returns: [<Promise>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Promise) Fulfills upon success with an object with two properties:
  - `bytesRead`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) The number of bytes read
  - `buffer`[<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<TypedArray>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/TypedArray) | [<DataView>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/DataView) A reference to the passed in`buffer` argument.

Reads data from the file and stores that in the given buffer.

If the file is not modified concurrently, the end-of-file is reached when the
number of bytes read is zero.

#### filehandle.read(buffer[, options])#

Added in: v18.2.0, v16.17.0
**History**

| Version | Changes |
| --- | --- |
| v21.0.0 | Accepts bigint values as `position`. |

- `buffer`[<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<TypedArray>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/TypedArray) | [<DataView>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/DataView) A buffer that will be filled with the
file data read.
- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `offset`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) The location in the buffer at which to start filling.**Default:**`0`
  - `length`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) The number of bytes to read.**Default:**`buffer.byteLength - offset`
  - `position`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<bigint>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#bigint_type) | [<null>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#null_type) The location where to begin reading data
from the file. If`null` or `-1`, data will be read from the current file
position, and the position will be updated. If `position` is a non-negative
integer, the current file position will remain unchanged. **Default:**: `null`

- Returns: [<Promise>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Promise) Fulfills upon success with an object with two properties:
  - `bytesRead`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) The number of bytes read
  - `buffer`[<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<TypedArray>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/TypedArray) | [<DataView>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/DataView) A reference to the passed in`buffer` argument.

Reads data from the file and stores that in the given buffer.

If the file is not modified concurrently, the end-of-file is reached when the
number of bytes read is zero.

#### filehandle.readableWebStream([options])#

Added in: v17.0.0
**History**

| Version | Changes |
| --- | --- |
| v24.0.0, v22.17.0 | Marking the API stable. |
| v23.8.0, v22.15.0 | Removed option to create a 'bytes' stream. Streams are now always 'bytes' streams. |
| v20.0.0, v18.17.0 | Added option to create a 'bytes' stream. |

- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `autoClose`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) When true, causes the [<FileHandle>](https://nodejs.org/api/fs.html#class-filehandle) to be closed when the
stream is closed.**Default:**`false`

- Returns: [<ReadableStream>](https://nodejs.org/api/webstreams.html#class-readablestream)

Returns a byte-oriented `ReadableStream` that may be used to read the file's
contents.

An error will be thrown if this method is called more than once or is called
after the `FileHandle` is closed or closing.

```mjs
import {
  open,
} from 'node:fs/promises';

const file = await open('./some/file/to/read');

for await (const chunk of file.readableWebStream())
  console.log(chunk);

await file.close();
const {
  open,
} = require('node:fs/promises');

(async () => {
  const file = await open('./some/file/to/read');

  for await (const chunk of file.readableWebStream())
    console.log(chunk);

  await file.close();
})();
javascriptcopy
```

While the `ReadableStream` will read the file to completion, it will not
close the `FileHandle` automatically. User code must still call the `fileHandle.close()` method unless the `autoClose` option is set to `true`.

#### filehandle.readFile(options)#

Added in: v10.0.0
- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object) | [<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type)
  - `encoding`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<null>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#null_type)**Default:**`null`
  - `signal`[<AbortSignal>](https://nodejs.org/api/globals.html#class-abortsignal) allows aborting an in-progress readFile

- Returns: [<Promise>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Promise) Fulfills upon a successful read with the contents of the
file. If no encoding is specified (using`options.encoding`), the data is
returned as a [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) object. Otherwise, the data will be a string.

Asynchronously reads the entire contents of a file.

If `options` is a string, then it specifies the `encoding`.

The [<FileHandle>](https://nodejs.org/api/fs.html#class-filehandle) has to support reading.

If one or more `filehandle.read()` calls are made on a file handle and then a `filehandle.readFile()` call is made, the data will be read from the current
position till the end of the file. It doesn't always read from the beginning
of the file.

#### filehandle.readLines([options])#

Added in: v18.11.0
- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `encoding`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type)**Default:**`null`
  - `autoClose`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type)**Default:**`true`
  - `emitClose`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type)**Default:**`true`
  - `start`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
  - `end`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)**Default:**`Infinity`
  - `highWaterMark`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)**Default:**`64 * 1024`

- Returns: [<readline.InterfaceConstructor>](https://nodejs.org/api/readline.html#class-readlineinterfaceconstructor)

Convenience method to create a `readline` interface and stream over the file.
See [filehandle.createReadStream()](#filehandlecreatereadstreamoptions) for the options.

```mjs
import { open } from 'node:fs/promises';

const file = await open('./some/file/to/read');

for await (const line of file.readLines()) {
  console.log(line);
}
const { open } = require('node:fs/promises');

(async () => {
  const file = await open('./some/file/to/read');

  for await (const line of file.readLines()) {
    console.log(line);
  }
})();
javascriptcopy
```

#### filehandle.readv(buffers[, position])#

Added in: v13.13.0, v12.17.0
- `buffers`[<Buffer[]>](buffer.html#class-buffer) | [<TypedArray[]>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/TypedArray) | [<DataView[]>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/DataView)
- `position`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<null>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#null_type) The offset from the beginning of the file where
the data should be read from. If`position` is not a `number`, the data will
be read from the current position. **Default:**`null`
- Returns: [<Promise>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Promise) Fulfills upon success an object containing two properties:
  - `bytesRead`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) the number of bytes read
  - `buffers`[<Buffer[]>](buffer.html#class-buffer) | [<TypedArray[]>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/TypedArray) | [<DataView[]>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/DataView) property containing
a reference to the`buffers` input.

Read from a file and write to an array of {ArrayBufferView}s

#### filehandle.stat([options])#

Added in: v10.0.0
**History**

| Version | Changes |
| --- | --- |
| v26.1.0 | Now accepts an additional `signal` property to allow aborting the operation. |
| v10.5.0 | Accepts an additional `options` object to specify whether the numeric values returned should be bigint. |

- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `bigint`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) Whether the numeric values in the returned [<fs.Stats>](https://nodejs.org/api/fs.html#class-fsstats) object should be`bigint`. **Default:**`false`.
  - `signal`[<AbortSignal>](https://nodejs.org/api/globals.html#class-abortsignal) An AbortSignal to cancel the operation.**Default:**`undefined`.

- Returns: [<Promise>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Promise) Fulfills with an [<fs.Stats>](https://nodejs.org/api/fs.html#class-fsstats) for the file.

#### filehandle.sync()#

Added in: v10.0.0
- Returns: [<Promise>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Promise) Fulfills with`undefined` upon success.

Request that all data for the open file descriptor is flushed to the storage
device. The specific implementation is operating system and device specific.
Refer to the POSIX [fsync(2)](http://man7.org/linux/man-pages/man2/fsync.2.html) documentation for more detail.

#### filehandle.truncate(len)#

Added in: v10.0.0
- `len`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)**Default:**`0`
- Returns: [<Promise>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Promise) Fulfills with`undefined` upon success.

Truncates the file.

If the file was larger than `len` bytes, only the first `len` bytes will be
retained in the file.

The following example retains only the first four bytes of the file:

```mjs
import { open } from 'node:fs/promises';

let filehandle = null;
try {
  filehandle = await open('temp.txt', 'r+');
  await filehandle.truncate(4);
} finally {
  await filehandle?.close();
}
mjscopy
```

If the file previously was shorter than `len` bytes, it is extended, and the
extended part is filled with null bytes (`'\0'`):

If `len` is negative then `0` will be used.

#### filehandle.utimes(atime, mtime)#

Added in: v10.0.0
- `atime`[<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Date>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Date)
- `mtime`[<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Date>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Date)
- Returns: [<Promise>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Promise)

Change the file system timestamps of the object referenced by the [<FileHandle>](https://nodejs.org/api/fs.html#class-filehandle) then fulfills the promise with no arguments upon success.

#### filehandle.write(buffer, offset[, length[, position]])#

Added in: v10.0.0
**History**

| Version | Changes |
| --- | --- |
| v14.0.0 | The `buffer` parameter won't coerce unsupported input to buffers anymore. |

- `buffer`[<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<TypedArray>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/TypedArray) | [<DataView>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/DataView)
- `offset`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) The start position from within`buffer` where the data
to write begins.
- `length`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) The number of bytes from`buffer` to write. **Default:**`buffer.byteLength - offset`
- `position`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<null>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#null_type) The offset from the beginning of the file where the
data from`buffer` should be written. If `position` is not a `number`,
the data will be written at the current position. See the POSIX [pwrite(2)](http://man7.org/linux/man-pages/man2/pwrite.2.html) documentation for more detail.**Default:**`null`
- Returns: [<Promise>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Promise)

Write `buffer` to the file.

The promise is fulfilled with an object containing two properties:

- `bytesWritten`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) the number of bytes written
- `buffer`[<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<TypedArray>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/TypedArray) | [<DataView>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/DataView) a reference to the`buffer` written.

It is unsafe to use `filehandle.write()` multiple times on the same file
without waiting for the promise to be fulfilled (or rejected). For this
scenario, use [filehandle.createWriteStream()](#filehandlecreatewritestreamoptions).

On Linux, positional writes do not work when the file is opened in append mode.
The kernel ignores the position argument and always appends the data to
the end of the file.

#### filehandle.write(buffer[, options])#

Added in: v18.3.0, v16.17.0
- `buffer`[<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<TypedArray>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/TypedArray) | [<DataView>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/DataView)
- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `offset`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)**Default:**`0`
  - `length`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)**Default:**`buffer.byteLength - offset`
  - `position`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<null>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#null_type)**Default:**`null`

- Returns: [<Promise>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Promise)

Write `buffer` to the file.

Similar to the above `filehandle.write` function, this version takes an
optional `options` object. If no `options` object is specified, it will
default with the above values.

#### filehandle.write(string[, position[, encoding]])#

Added in: v10.0.0
**History**

| Version | Changes |
| --- | --- |
| v14.0.0 | The `string` parameter won't coerce unsupported input to strings anymore. |

- `string`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type)
- `position`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<null>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#null_type) The offset from the beginning of the file where the
data from`string` should be written. If `position` is not a `number`the
data will be written at the current position. See the POSIX [pwrite(2)](http://man7.org/linux/man-pages/man2/pwrite.2.html) documentation for more detail.**Default:**`null`
- `encoding`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) The expected string encoding.**Default:**`'utf8'`
- Returns: [<Promise>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Promise)

Write `string` to the file. If `string` is not a string, the promise is
rejected with an error.

The promise is fulfilled with an object containing two properties:

- `bytesWritten`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) the number of bytes written
- `buffer`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) a reference to the`string` written.

It is unsafe to use `filehandle.write()` multiple times on the same file
without waiting for the promise to be fulfilled (or rejected). For this
scenario, use [filehandle.createWriteStream()](#filehandlecreatewritestreamoptions).

On Linux, positional writes do not work when the file is opened in append mode.
The kernel ignores the position argument and always appends the data to
the end of the file.

#### filehandle.writeFile(data, options)#

Added in: v10.0.0
**History**

| Version | Changes |
| --- | --- |
| v15.14.0, v14.18.0 | The `data` argument supports `AsyncIterable`, `Iterable`, and `Stream`. |
| v14.0.0 | The `data` parameter won't coerce unsupported input to strings anymore. |

- `data`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<TypedArray>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/TypedArray) | [<DataView>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/DataView) | [<AsyncIterable>](https://tc39.github.io/ecma262/#sec-asynciterable-interface) | [<Stream>](https://nodejs.org/api/stream.html#stream)
- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object) | [<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type)
  - `encoding`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<null>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#null_type) The expected character encoding when`data` is a
string. **Default:**`'utf8'`
  - `signal`[<AbortSignal>](https://nodejs.org/api/globals.html#class-abortsignal) | [<undefined>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#undefined_type) allows aborting an in-progress writeFile.**Default:**`undefined`

- Returns: [<Promise>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Promise)

Asynchronously writes data to a file, replacing the file if it already exists. `data`can be a string, a buffer, an [<AsyncIterable>](https://tc39.github.io/ecma262/#sec-asynciterable-interface), or an {Iterable} object.
The promise is fulfilled with no arguments upon success.

If `options` is a string, then it specifies the `encoding`.

The [<FileHandle>](https://nodejs.org/api/fs.html#class-filehandle) has to support writing.

It is unsafe to use `filehandle.writeFile()` multiple times on the same file
without waiting for the promise to be fulfilled (or rejected).

If one or more `filehandle.write()` calls are made on a file handle and then a `filehandle.writeFile()` call is made, the data will be written from the
current position till the end of the file. It doesn't always write from the
beginning of the file.

#### filehandle.writev(buffers[, position])#

Added in: v12.9.0
- `buffers`[<Buffer[]>](buffer.html#class-buffer) | [<TypedArray[]>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/TypedArray) | [<DataView[]>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/DataView)
- `position`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<null>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#null_type) The offset from the beginning of the file where the
data from`buffers` should be written. If `position` is not a `number`,
the data will be written at the current position. **Default:**`null`
- Returns: [<Promise>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Promise)

Write an array of {ArrayBufferView}s to the file.

The promise is fulfilled with an object containing a two properties:

- `bytesWritten`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) the number of bytes written
- `buffers`[<Buffer[]>](buffer.html#class-buffer) | [<TypedArray[]>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/TypedArray) | [<DataView[]>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/DataView) a reference to the`buffers` input.

It is unsafe to call `writev()` multiple times on the same file without waiting
for the promise to be fulfilled (or rejected).

On Linux, positional writes don't work when the file is opened in append mode.
The kernel ignores the position argument and always appends the data to
the end of the file.

#### filehandle.writer([options])#

Added in: v25.9.0
Stability: 1 - Experimental

- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `autoClose`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) Close the file handle when the writer ends or
fails.**Default:**`false`.
  - `start`[<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) Byte offset to start writing at. When specified,
writes use explicit positioning.**Default:** current file position.
  - `limit`[<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) Maximum number of bytes the writer will accept.
Async writes (`write()`, `writev()`) that would exceed the limit reject
with `ERR_OUT_OF_RANGE`. Sync writes (`writeSync()`, `writevSync()`)
return `false`. **Default:** no limit.
  - `chunkSize`[<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) Maximum chunk size in bytes for synchronous write
operations. Writes larger than this threshold fall back to async I/O.
Set this to match the reader's`chunkSize` for optimal `pipeTo()` performance. **Default:**`131072` (128 KB).

- Returns: [<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `write(chunk[, options])`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function) Returns [<Promise>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Promise).
Accepts`Uint8Array`, `Buffer`, or string (UTF-8 encoded).
    - `chunk`[<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<TypedArray>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/TypedArray) | [<DataView>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/DataView) | [<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type)
    - `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
      - `signal`[<AbortSignal>](https://nodejs.org/api/globals.html#class-abortsignal) If the signal is already aborted, the write
rejects with`AbortError` without performing I/O.

  - `writev(chunks[, options])`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function) Returns [<Promise>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Promise). Uses
scatter/gather I/O via a single`writev()` syscall. Accepts mixed `Uint8Array`/string arrays.
    - `chunks`[<Buffer[]>](buffer.html#class-buffer) | [<TypedArray[]>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/TypedArray) | [<DataView[]>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/DataView) | [<string[]>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type)
    - `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
      - `signal`[<AbortSignal>](https://nodejs.org/api/globals.html#class-abortsignal) If the signal is already aborted, the write
rejects with`AbortError` without performing I/O.

  - `writeSync(chunk)`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function) Returns [<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type). Attempts a synchronous
write. Returns`true` if the write succeeded, `false` if the caller
should fall back to async `write()`. Returns `false` when: the writer
is closed/errored, an async operation is in flight, the chunk exceeds `chunkSize`, or the write would exceed `limit`.
    - `chunk`[<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<TypedArray>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/TypedArray) | [<DataView>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/DataView) | [<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type)

  - `writevSync(chunks)`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function) Returns [<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type). Synchronous batch
write. Same fallback semantics as`writeSync()`.
    - `chunks`[<Buffer[]>](buffer.html#class-buffer) | [<TypedArray[]>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/TypedArray) | [<DataView[]>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/DataView) | [<string[]>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type)

  - `end([options])`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function) Returns [<Promise>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Promise), fulfills with the total
number of bytes written. Idempotent: returns`totalBytesWritten` if already
closed, returns the pending promise if already closing. Rejects if the writer
is in an errored state.
    - `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
      - `signal`[<AbortSignal>](https://nodejs.org/api/globals.html#class-abortsignal) If the signal is already aborted,`end()` rejects with `AbortError` and the writer remains open.

  - `endSync()`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function) Returns [<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) total bytes written on
success,`-1` if the writer is errored or an async operation is in
flight. Idempotent when already closed.
  - `fail(reason)`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function) Puts the writer into a terminal error state.
Synchronous. If the writer is already closed or errored, this is a
no-op. If`autoClose` is true, closes the file handle synchronously.

Return a [node:stream/iter](https://nodejs.org/api/stream_iter.html) writer backed by this file handle.

The writer supports both `Symbol.asyncDispose` and `Symbol.dispose`:

- `await using w = fh.writer()` — if the writer is still open (no `end()` called), `asyncDispose` calls `fail()`. If `end()` is pending, it waits
for it to complete.
- `using w = fh.writer()` — calls `fail()` unconditionally.

The `writeSync()` and `writevSync()` methods enable the try-sync fast path
used by [stream/iter pipeTo()](https://nodejs.org/api/stream_iter.html#pipetosource-transforms-writer). When the reader's chunk size matches the
writer's `chunkSize`, all writes in a `pipeTo()` pipeline complete
synchronously with zero promise overhead.

This function is only available when the `--experimental-stream-iter` flag is
enabled.

```mjs
import { open } from 'node:fs/promises';
import { from, pipeTo } from 'node:stream/iter';
import { compressGzip } from 'node:zlib/iter';

// Async pipeline
const fh = await open('output.gz', 'w');
await pipeTo(from('Hello!'), compressGzip(), fh.writer({ autoClose: true }));

// Sync pipeline with limit
const src = await open('input.txt', 'r');
const dst = await open('output.txt', 'w');
const w = dst.writer({ limit: 1024 * 1024 }); // Max 1 MB
await pipeTo(src.pull({ autoClose: true }), w);
await w.end();
await dst.close();
const { open } = require('node:fs/promises');
const { from, pipeTo } = require('node:stream/iter');
const { compressGzip } = require('node:zlib/iter');

async function run() {
  // Async pipeline
  const fh = await open('output.gz', 'w');
  await pipeTo(from('Hello!'), compressGzip(), fh.writer({ autoClose: true }));

  // Sync pipeline with limit
  const src = await open('input.txt', 'r');
  const dst = await open('output.txt', 'w');
  const w = dst.writer({ limit: 1024 * 1024 }); // Max 1 MB
  await pipeTo(src.pull({ autoClose: true }), w);
  await w.end();
  await dst.close();
}

run().catch(console.error);
javascriptcopy
```

#### filehandle[Symbol.asyncDispose]()#

Added in: v20.4.0, v18.18.0
**History**

| Version | Changes |
| --- | --- |
| v24.2.0 | No longer experimental. |

Calls `filehandle.close()` and returns a promise that fulfills when the
filehandle is closed.

#### fsPromises.access(path[, mode])#

Added in: v10.0.0
- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `mode`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)**Default:**`fs.constants.F_OK`
- Returns: [<Promise>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Promise) Fulfills with`undefined` upon success.

Tests a user's permissions for the file or directory specified by `path`.
The `mode` argument is an optional integer that specifies the accessibility
checks to be performed. `mode` should be either the value `fs.constants.F_OK` or a mask consisting of the bitwise OR of any of `fs.constants.R_OK`, `fs.constants.W_OK`, and `fs.constants.X_OK` (e.g. `fs.constants.W_OK | fs.constants.R_OK`). Check [File access constants](#file-access-constants) for
possible values of `mode`.

If the accessibility check is successful, the promise is fulfilled with no
value. If any of the accessibility checks fail, the promise is rejected
with an [<Error>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Error) object. The following example checks if the file`/etc/passwd` can be read and written by the current process.

```mjs
import { access, constants } from 'node:fs/promises';

try {
  await access('/etc/passwd', constants.R_OK | constants.W_OK);
  console.log('can access');
} catch {
  console.error('cannot access');
}
mjscopy
```

Using `fsPromises.access()` to check for the accessibility of a file before
calling `fsPromises.open()` is not recommended. Doing so introduces a race
condition, since other processes may change the file's state between the two
calls. Instead, user code should open/read/write the file directly and handle
the error raised if the file is not accessible.

#### fsPromises.appendFile(path, data[, options])#

Added in: v10.0.0
**History**

| Version | Changes |
| --- | --- |
| v21.1.0, v20.10.0 | The `flush` option is now supported. |

- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api) | [<FileHandle>](https://nodejs.org/api/fs.html#class-filehandle) filename or [<FileHandle>](https://nodejs.org/api/fs.html#class-filehandle)
- `data`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer)
- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object) | [<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type)
  - `encoding`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<null>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#null_type)**Default:**`'utf8'`
  - `mode`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)**Default:**`0o666`
  - `flag`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) See[support of file system flags](#file-system-flags). **Default:**`'a'`.
  - `flush`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) If`true`, the underlying file descriptor is flushed
prior to closing it. **Default:**`false`.

- Returns: [<Promise>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Promise) Fulfills with`undefined` upon success.

Asynchronously append data to a file, creating the file if it does not yet
exist. `data`can be a string or a [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer).

If `options` is a string, then it specifies the `encoding`.

The `mode` option only affects the newly created file. See [fs.open()](#fsopenpath-flags-mode-callback) for more details.

The `path`may be specified as a [<FileHandle>](https://nodejs.org/api/fs.html#class-filehandle) that has been opened
for appending (using`fsPromises.open()`).

#### fsPromises.chmod(path, mode)#

Added in: v10.0.0
- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `mode`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
- Returns: [<Promise>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Promise) Fulfills with`undefined` upon success.

Changes the permissions of a file.

#### fsPromises.chown(path, uid, gid)#

Added in: v10.0.0
- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `uid`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
- `gid`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
- Returns: [<Promise>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Promise) Fulfills with`undefined` upon success.

Changes the ownership of a file.

#### fsPromises.copyFile(src, dest[, mode])#

Added in: v10.0.0
**History**

| Version | Changes |
| --- | --- |
| v14.0.0 | Changed `flags` argument to `mode` and imposed stricter type validation. |

- `src`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api) source filename to copy
- `dest`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api) destination filename of the copy operation
- `mode`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) Optional modifiers that specify the behavior of the copy
operation. It is possible to create a mask consisting of the bitwise OR of
two or more values (e.g.`fs.constants.COPYFILE_EXCL | fs.constants.COPYFILE_FICLONE`) **Default:**`0`.
  - `fs.constants.COPYFILE_EXCL`: The copy operation will fail if `dest` already exists.
  - `fs.constants.COPYFILE_FICLONE`: The copy operation will attempt to create
a copy-on-write reflink. If the platform does not support copy-on-write,
then a fallback copy mechanism is used.
  - `fs.constants.COPYFILE_FICLONE_FORCE`: The copy operation will attempt to
create a copy-on-write reflink. If the platform does not support
copy-on-write, then the operation will fail.

- Returns: [<Promise>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Promise) Fulfills with`undefined` upon success.

Asynchronously copies `src` to `dest`. By default, `dest` is overwritten if it
already exists.

No guarantees are made about the atomicity of the copy operation. If an
error occurs after the destination file has been opened for writing, an attempt
will be made to remove the destination.

```mjs
import { copyFile, constants } from 'node:fs/promises';

try {
  await copyFile('source.txt', 'destination.txt');
  console.log('source.txt was copied to destination.txt');
} catch {
  console.error('The file could not be copied');
}

// By using COPYFILE_EXCL, the operation will fail if destination.txt exists.
try {
  await copyFile('source.txt', 'destination.txt', constants.COPYFILE_EXCL);
  console.log('source.txt was copied to destination.txt');
} catch {
  console.error('The file could not be copied');
}
mjscopy
```

#### fsPromises.cp(src, dest[, options])#

Added in: v16.7.0
**History**

| Version | Changes |
| --- | --- |
| v22.3.0 | This API is no longer experimental. |
| v20.1.0, v18.17.0 | Accept an additional `mode` option to specify the copy behavior as the `mode` argument of `fs.copyFile()`. |
| v17.6.0, v16.15.0 | Accepts an additional `verbatimSymlinks` option to specify whether to perform path resolution for symlinks. |

- `src`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api) source path to copy.
- `dest`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api) destination path to copy to.
- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `dereference`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) dereference symlinks.**Default:**`false`.
  - `errorOnExist`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) when`force` is `false`, and the destination
exists, throw an error. **Default:**`false`.
  - `filter`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function) Function to filter copied files/directories. Return`true` to copy the item, `false` to ignore it. When ignoring a directory,
all of its contents will be skipped as well. Can also return a `Promise` that resolves to `true` or `false`**Default:**`undefined`.
    - `src`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) source path to copy.
    - `dest`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) destination path to copy to.
    - Returns: [<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) | [<Promise>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Promise) A value that is coercible to`boolean` or
a `Promise` that fulfils with such value.

  - `force`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) overwrite existing file or directory. The copy
operation will ignore errors if you set this to false and the destination
exists. Use the`errorOnExist` option to change this behavior. **Default:**`true`.
  - `mode`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) modifiers for copy operation.**Default:**`0`.
See `mode` flag of [fsPromises.copyFile()](#fspromisescopyfilesrc-dest-mode).
  - `preserveTimestamps`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) When`true` timestamps from `src` will
be preserved. **Default:**`false`.
  - `recursive`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) copy directories recursively**Default:**`false`
  - `verbatimSymlinks`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) When`true`, path resolution for symlinks will
be skipped. **Default:**`false`

- Returns: [<Promise>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Promise) Fulfills with`undefined` upon success.

Asynchronously copies the entire directory structure from `src` to `dest`,
including subdirectories and files.

When copying a directory to another directory, globs are not supported and
behavior is similar to `cp dir1/ dir2/`.

#### fsPromises.glob(pattern[, options])#

Added in: v22.0.0
**History**

| Version | Changes |
| --- | --- |
| v26.1.0 | Add support for the `followSymlinks` option. |
| v24.1.0, v22.17.0 | Add support for `URL` instances for `cwd` option. |
| v24.0.0, v22.17.0 | Marking the API stable. |
| v23.7.0, v22.14.0 | Add support for `exclude` option to accept glob patterns. |
| v22.2.0 | Add support for `withFileTypes` as an option. |

- `pattern`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<string[]>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type)
- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `cwd`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api) current working directory.**Default:**`process.cwd()`
  - `exclude`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function) | [<string[]>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) Function to filter out files/directories or a
list of glob patterns to be excluded. If a function is provided, return`true` to exclude the item, `false` to include it. **Default:**`undefined`.
If a string array is provided, each string should be a glob pattern that
specifies paths to exclude. Note: Negation patterns (e.g., '!foo.js') are
not supported.
  - `followSymlinks`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) When`true`, symbolic links to directories are
followed while expanding `**` patterns. **Default:**`false`.
  - `withFileTypes`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type)`true` if the glob should return paths as Dirents, `false` otherwise. **Default:**`false`.

- Returns: [<AsyncIterator>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/AsyncIterator) An AsyncIterator that yields the paths of files
that match the pattern.

When `followSymlinks` is enabled, detected symbolic link cycles are not
traversed recursively.

```mjs
import { glob } from 'node:fs/promises';

for await (const entry of glob('**/*.js'))
  console.log(entry);
const { glob } = require('node:fs/promises');

(async () => {
  for await (const entry of glob('**/*.js'))
    console.log(entry);
})();
javascriptcopy
```

#### fsPromises.lchmod(path, mode)#

Deprecated in: v10.0.0
Stability: 0 - Deprecated

- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `mode`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
- Returns: [<Promise>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Promise) Fulfills with`undefined` upon success.

Changes the permissions on a symbolic link.

This method is only implemented on macOS.

#### fsPromises.lchown(path, uid, gid)#

Added in: v10.0.0
**History**

| Version | Changes |
| --- | --- |
| v10.6.0 | This API is no longer deprecated. |

- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `uid`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
- `gid`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
- Returns: [<Promise>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Promise) Fulfills with`undefined` upon success.

Changes the ownership on a symbolic link.

#### fsPromises.lutimes(path, atime, mtime)#

Added in: v14.5.0, v12.19.0
- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `atime`[<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Date>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Date)
- `mtime`[<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Date>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Date)
- Returns: [<Promise>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Promise) Fulfills with`undefined` upon success.

Changes the access and modification times of a file in the same way as [fsPromises.utimes()](#fspromisesutimespath-atime-mtime), with the difference that if the path refers to a
symbolic link, then the link is not dereferenced: instead, the timestamps of
the symbolic link itself are changed.

#### fsPromises.link(existingPath, newPath)#

Added in: v10.0.0
- `existingPath`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `newPath`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- Returns: [<Promise>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Promise) Fulfills with`undefined` upon success.

Creates a new link from the `existingPath` to the `newPath`. See the POSIX [link(2)](http://man7.org/linux/man-pages/man2/link.2.html) documentation for more detail.

#### fsPromises.lstat(path[, options])#

Added in: v10.0.0
**History**

| Version | Changes |
| --- | --- |
| v10.5.0 | Accepts an additional `options` object to specify whether the numeric values returned should be bigint. |

- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `bigint`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) Whether the numeric values in the returned [<fs.Stats>](https://nodejs.org/api/fs.html#class-fsstats) object should be`bigint`. **Default:**`false`.

- Returns: [<Promise>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Promise) Fulfills with the [<fs.Stats>](https://nodejs.org/api/fs.html#class-fsstats) object for the given
symbolic link`path`.

Equivalent to [fsPromises.stat()](#fspromisesstatpath-options) unless `path`refers to a symbolic link,
in which case the link itself is stat-ed, not the file that it refers to.
Refer to the POSIX [lstat(2)](http://man7.org/linux/man-pages/man2/lstat.2.html) document for more detail.

#### fsPromises.mkdir(path[, options])#

Added in: v10.0.0
- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object) | [<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
  - `recursive`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type)**Default:**`false`
  - `mode`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) Not supported on Windows. See[File modes](#file-modes) for more details. **Default:**`0o777`.

- Returns: [<Promise>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Promise) Upon success, fulfills with`undefined` if `recursive` is `false`, or the first directory path created if `recursive` is `true`.

Asynchronously creates a directory.

The optional `options` argument can be an integer specifying `mode` (permission
and sticky bits), or an object with a `mode` property and a `recursive` property indicating whether parent directories should be created. Calling `fsPromises.mkdir()` when `path` is a directory that exists results in a
rejection only when `recursive` is false.

```mjs
import { mkdir } from 'node:fs/promises';

try {
  const projectFolder = new URL('./test/project/', import.meta.url);
  const createDir = await mkdir(projectFolder, { recursive: true });

  console.log(`created ${createDir}`);
} catch (err) {
  console.error(err.message);
}
const { mkdir } = require('node:fs/promises');
const { join } = require('node:path');

async function makeDirectory() {
  const projectFolder = join(__dirname, 'test', 'project');
  const dirCreation = await mkdir(projectFolder, { recursive: true });

  console.log(dirCreation);
  return dirCreation;
}

makeDirectory().catch(console.error);
javascriptcopy
```

#### fsPromises.mkdtemp(prefix[, options])#

Added in: v10.0.0
**History**

| Version | Changes |
| --- | --- |
| v20.6.0, v18.19.0 | The `prefix` parameter now accepts buffers and URL. |
| v16.5.0, v14.18.0 | The `prefix` parameter now accepts an empty string. |

- `prefix`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `options`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `encoding`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type)**Default:**`'utf8'`

- Returns: [<Promise>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Promise) Fulfills with a string containing the file system path
of the newly created temporary directory.

Creates a unique temporary directory. A unique directory name is generated by
appending six random characters to the end of the provided `prefix`. Due to
platform inconsistencies, avoid trailing `X` characters in `prefix`. Some
platforms, notably the BSDs, can return more than six random characters, and
replace trailing `X` characters in `prefix` with random characters.

The optional `options` argument can be a string specifying an encoding, or an
object with an `encoding` property specifying the character encoding to use.

```mjs
import { mkdtemp } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

try {
  await mkdtemp(join(tmpdir(), 'foo-'));
} catch (err) {
  console.error(err);
}
mjscopy
```

The `fsPromises.mkdtemp()` method will append the six randomly selected
characters directly to the `prefix` string. For instance, given a directory `/tmp`, if the intention is to create a temporary directory _within_`/tmp`, the `prefix` must end with a trailing platform-specific path separator
(`require('node:path').sep`).

#### fsPromises.mkdtempDisposable(prefix[, options])#

Added in: v24.4.0
- `prefix`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `options`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `encoding`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type)**Default:**`'utf8'`

- Returns: [<Promise>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Promise) Fulfills with a Promise for an async-disposable Object:
  - `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) The path of the created directory.
  - `remove`[<AsyncFunction>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/AsyncFunction) A function which removes the created directory.
  - `[Symbol.asyncDispose]`[<AsyncFunction>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/AsyncFunction) The same as`remove`.

The resulting Promise holds an async-disposable object whose `path` property
holds the created directory path. When the object is disposed, the directory
and its contents will be removed asynchronously if it still exists. If the
directory cannot be deleted, disposal will throw an error. The object has an
async `remove()` method which will perform the same task.

Both this function and the disposal function on the resulting object are
async, so it should be used with `await` + `await using` as in `await using dir = await fsPromises.mkdtempDisposable('prefix')`.

For detailed information, see the documentation of [fsPromises.mkdtemp()](#fspromisesmkdtempprefix-options).

The optional `options` argument can be a string specifying an encoding, or an
object with an `encoding` property specifying the character encoding to use.

#### fsPromises.open(path, flags[, mode])#

Added in: v10.0.0
**History**

| Version | Changes |
| --- | --- |
| v11.1.0 | The `flags` argument is now optional and defaults to `'r'`. |

- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `flags`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) See[support of file system flags](#file-system-flags). **Default:**`'r'`.
- `mode`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) Sets the file mode (permission and sticky bits)
if the file is created. See[File modes](#file-modes) for more details. **Default:**`0o666` (readable and writable)
- Returns: [<Promise>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Promise) Fulfills with a [<FileHandle>](https://nodejs.org/api/fs.html#class-filehandle) object.

Opens a [<FileHandle>](https://nodejs.org/api/fs.html#class-filehandle).

Refer to the POSIX [open(2)](http://man7.org/linux/man-pages/man2/open.2.html) documentation for more detail.

Some characters (`< > : " / \ | ? *`) are reserved under Windows as documented
by [Naming Files, Paths, and Namespaces](https://docs.microsoft.com/en-us/windows/desktop/FileIO/naming-a-file). Under NTFS, if the filename contains
a colon, Node.js will open a file system stream, as described by [this MSDN page](https://docs.microsoft.com/en-us/windows/desktop/FileIO/using-streams).

#### fsPromises.opendir(path[, options])#

Added in: v12.12.0
**History**

| Version | Changes |
| --- | --- |
| v20.1.0, v18.17.0 | Added `recursive` option. |
| v13.1.0, v12.16.0 | The `bufferSize` option was introduced. |

- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `encoding`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<null>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#null_type)**Default:**`'utf8'`
  - `bufferSize`[<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) Number of directory entries that are buffered
internally when reading from the directory. Higher values lead to better
performance but higher memory usage.**Default:**`32`
  - `recursive`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) Resolved`Dir`will be an [<AsyncIterable>](https://tc39.github.io/ecma262/#sec-asynciterable-interface) containing all sub files and directories.**Default:**`false`

- Returns: [<Promise>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Promise) Fulfills with an [<fs.Dir>](https://nodejs.org/api/fs.html#class-fsdir).

Asynchronously open a directory for iterative scanning. See the POSIX [opendir(3)](http://man7.org/linux/man-pages/man3/opendir.3.html) documentation for more detail.

Creates an [<fs.Dir>](https://nodejs.org/api/fs.html#class-fsdir), which contains all further functions for reading from
and cleaning up the directory.

The `encoding` option sets the encoding for the `path` while opening the
directory and subsequent read operations.

Example using async iteration:

```mjs
import { opendir } from 'node:fs/promises';

try {
  const dir = await opendir('./');
  for await (const dirent of dir)
    console.log(dirent.name);
} catch (err) {
  console.error(err);
}
mjscopy
```

When using the async iterator, the [<fs.Dir>](https://nodejs.org/api/fs.html#class-fsdir) object will be automatically
closed after the iterator exits.

#### fsPromises.readdir(path[, options])#

Added in: v10.0.0
**History**

| Version | Changes |
| --- | --- |
| v20.1.0, v18.17.0 | Added `recursive` option. |
| v10.11.0 | New option `withFileTypes` was added. |

- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `options`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `encoding`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type)**Default:**`'utf8'`
  - `withFileTypes`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type)**Default:**`false`
  - `recursive`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) If`true`, reads the contents of a directory
recursively. In recursive mode, it will list all files, sub files, and
directories. **Default:**`false`.

- Returns: [<Promise>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Promise) Fulfills with an array of the names of the files in
the directory excluding`'.'` and `'..'`.

Reads the contents of a directory.

The optional `options` argument can be a string specifying an encoding, or an
object with an `encoding` property specifying the character encoding to use for
the filenames. If the `encoding` is set to `'buffer'`, the filenames returned
will be passed as [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) objects.

If `options.withFileTypes` is set to `true`, the returned array will contain [<fs.Dirent>](https://nodejs.org/api/fs.html#class-fsdirent) objects.

```mjs
import { readdir } from 'node:fs/promises';

try {
  const files = await readdir(path);
  for (const file of files)
    console.log(file);
} catch (err) {
  console.error(err);
}
mjscopy
```

#### fsPromises.readFile(path[, options])#

Added in: v10.0.0
**History**

| Version | Changes |
| --- | --- |
| v15.2.0, v14.17.0 | The options argument may include an AbortSignal to abort an ongoing readFile request. |

- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api) | [<FileHandle>](https://nodejs.org/api/fs.html#class-filehandle) filename or`FileHandle`
- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object) | [<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type)
  - `encoding`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<null>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#null_type)**Default:**`null`
  - `flag`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) See[support of file system flags](#file-system-flags). **Default:**`'r'`.
  - `signal`[<AbortSignal>](https://nodejs.org/api/globals.html#class-abortsignal) allows aborting an in-progress readFile

- Returns: [<Promise>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Promise) Fulfills with the contents of the file.

Asynchronously reads the entire contents of a file.

If no encoding is specified (using `options.encoding`), the data is returned
as a [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) object. Otherwise, the data will be a string.

If `options` is a string, then it specifies the encoding.

When the `path` is a directory, the behavior of `fsPromises.readFile()` is
platform-specific. On macOS, Linux, and Windows, the promise will be rejected
with an error. On FreeBSD, a representation of the directory's contents will be
returned.

An example of reading a `package.json` file located in the same directory of the
running code:

```mjs
import { readFile } from 'node:fs/promises';
try {
  const filePath = new URL('./package.json', import.meta.url);
  const contents = await readFile(filePath, { encoding: 'utf8' });
  console.log(contents);
} catch (err) {
  console.error(err.message);
}
const { readFile } = require('node:fs/promises');
const { resolve } = require('node:path');
async function logFile() {
  try {
    const filePath = resolve('./package.json');
    const contents = await readFile(filePath, { encoding: 'utf8' });
    console.log(contents);
  } catch (err) {
    console.error(err.message);
  }
}
logFile();
javascriptcopy
```

It is possible to abort an ongoing `readFile`using an [<AbortSignal>](https://nodejs.org/api/globals.html#class-abortsignal). If a
request is aborted the promise returned is rejected with an`AbortError`:

```mjs
import { readFile } from 'node:fs/promises';

try {
  const controller = new AbortController();
  const { signal } = controller;
  const promise = readFile(fileName, { signal });

  // Abort the request before the promise settles.
  controller.abort();

  await promise;
} catch (err) {
  // When a request is aborted - err is an AbortError
  console.error(err);
}
mjscopy
```

Aborting an ongoing request does not abort individual operating
system requests but rather the internal buffering `fs.readFile` performs.

Any specified [<FileHandle>](https://nodejs.org/api/fs.html#class-filehandle) has to support reading.

#### fsPromises.readlink(path[, options])#

Added in: v10.0.0
- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `options`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `encoding`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type)**Default:**`'utf8'`

- Returns: [<Promise>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Promise) Fulfills with the`linkString` upon success.

Reads the contents of the symbolic link referred to by `path`. See the POSIX [readlink(2)](http://man7.org/linux/man-pages/man2/readlink.2.html) documentation for more detail. The promise is fulfilled with the`linkString` upon success.

The optional `options` argument can be a string specifying an encoding, or an
object with an `encoding` property specifying the character encoding to use for
the link path returned. If the `encoding` is set to `'buffer'`, the link path
returned will be passed as a [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) object.

#### fsPromises.realpath(path[, options])#

Added in: v10.0.0
- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `options`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `encoding`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type)**Default:**`'utf8'`

- Returns: [<Promise>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Promise) Fulfills with the resolved path upon success.

Determines the actual location of `path` using the same semantics as the `fs.realpath.native()` function.

Only paths that can be converted to UTF8 strings are supported.

The optional `options` argument can be a string specifying an encoding, or an
object with an `encoding` property specifying the character encoding to use for
the path. If the `encoding` is set to `'buffer'`, the path returned will be
passed as a [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) object.

On Linux, when Node.js is linked against musl libc, the procfs file system must
be mounted on `/proc` in order for this function to work. Glibc does not have
this restriction.

#### fsPromises.rename(oldPath, newPath)#

Added in: v10.0.0
- `oldPath`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `newPath`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- Returns: [<Promise>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Promise) Fulfills with`undefined` upon success.

Renames `oldPath` to `newPath`.

#### fsPromises.rmdir(path[, options])#

Added in: v10.0.0
**History**

| Version | Changes |
| --- | --- |
| v25.0.0 | Remove `recursive` option. |
| v16.0.0 | Using `fsPromises.rmdir(path, { recursive: true })` on a `path` that is a file is no longer permitted and results in an `ENOENT` error on Windows and an `ENOTDIR` error on POSIX. |
| v16.0.0 | Using `fsPromises.rmdir(path, { recursive: true })` on a `path` that does not exist is no longer permitted and results in a `ENOENT` error. |
| v16.0.0 | The `recursive` option is deprecated, using it triggers a deprecation warning. |
| v14.14.0 | The `recursive` option is deprecated, use `fsPromises.rm` instead. |
| v13.3.0, v12.16.0 | The `maxBusyTries` option is renamed to `maxRetries`, and its default is 0. The `emfileWait` option has been removed, and `EMFILE` errors use the same retry logic as other errors. The `retryDelay` option is now supported. `ENFILE` errors are now retried. |
| v12.10.0 | The `recursive`, `maxBusyTries`, and `emfileWait` options are now supported. |

- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object) There are currently no options exposed. There used to
be options for`recursive`, `maxBusyTries`, and `emfileWait` but they were
deprecated and removed. The `options` argument is still accepted for
backwards compatibility but it is not used.
- Returns: [<Promise>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Promise) Fulfills with`undefined` upon success.

Removes the directory identified by `path`.

Using `fsPromises.rmdir()` on a file (not a directory) results in the
promise being rejected with an `ENOENT` error on Windows and an `ENOTDIR` error on POSIX.

To get a behavior similar to the `rm -rf` Unix command, use [fsPromises.rm()](#fspromisesrmpath-options) with options `{ recursive: true, force: true }`.

#### fsPromises.rm(path[, options])#

Added in: v14.14.0
- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `force`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) When`true`, exceptions will be ignored if `path` does
not exist. **Default:**`false`.
  - `maxRetries`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) If an`EBUSY`, `EMFILE`, `ENFILE`, `ENOTEMPTY`, or `EPERM` error is encountered, Node.js will retry the operation with a linear
backoff wait of `retryDelay` milliseconds longer on each try. This option
represents the number of retries. This option is ignored if the `recursive` option is not `true`. **Default:**`0`.
  - `recursive`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) If`true`, perform a recursive directory removal. In
recursive mode operations are retried on failure. **Default:**`false`.
  - `retryDelay`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) The amount of time in milliseconds to wait between
retries. This option is ignored if the`recursive` option is not `true`. **Default:**`100`.

- Returns: [<Promise>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Promise) Fulfills with`undefined` upon success.

Removes files and directories (modeled on the standard POSIX `rm` utility).

#### fsPromises.stat(path[, options])#

Added in: v10.0.0
**History**

| Version | Changes |
| --- | --- |
| v25.7.0 | Accepts a `throwIfNoEntry` option to specify whether an exception should be thrown if the entry does not exist. |
| v10.5.0 | Accepts an additional `options` object to specify whether the numeric values returned should be bigint. |

- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `bigint`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) Whether the numeric values in the returned [<fs.Stats>](https://nodejs.org/api/fs.html#class-fsstats) object should be`bigint`. **Default:**`false`.
  - `throwIfNoEntry`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) Whether an exception will be thrown
if no file system entry exists, rather than returning`undefined`. **Default:**`true`.

- Returns: [<Promise>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Promise) Fulfills with the [<fs.Stats>](https://nodejs.org/api/fs.html#class-fsstats) object for the
given`path`.

#### fsPromises.statfs(path[, options])#

Added in: v19.6.0, v18.15.0
- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `bigint`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) Whether the numeric values in the returned [<fs.StatFs>](https://nodejs.org/api/fs.html#class-fsstatfs) object should be`bigint`. **Default:**`false`.

- Returns: [<Promise>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Promise) Fulfills with the [<fs.StatFs>](https://nodejs.org/api/fs.html#class-fsstatfs) object for the
given`path`.

#### fsPromises.symlink(target, path[, type])#

Added in: v10.0.0
**History**

| Version | Changes |
| --- | --- |
| v19.0.0 | If the `type` argument is `null` or omitted, Node.js will autodetect `target` type and automatically select `dir` or `file`. |

- `target`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `type`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<null>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#null_type)**Default:**`null`
- Returns: [<Promise>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Promise) Fulfills with`undefined` upon success.

Creates a symbolic link.

The `type` argument is only used on Windows platforms and can be one of `'dir'`, `'file'`, or `'junction'`. If the `type` argument is `null`, Node.js will
autodetect `target` type and use `'file'` or `'dir'`. If the `target` does not
exist, `'file'` will be used. Windows junction points require the destination
path to be absolute. When using `'junction'`, the `target` argument will
automatically be normalized to absolute path. Junction points on NTFS volumes
can only point to directories.

#### fsPromises.truncate(path[, len])#

Added in: v10.0.0
- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `len`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)**Default:**`0`
- Returns: [<Promise>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Promise) Fulfills with`undefined` upon success.

Truncates (shortens or extends the length) of the content at `path` to `len` bytes.

#### fsPromises.unlink(path)#

Added in: v10.0.0
- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- Returns: [<Promise>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Promise) Fulfills with`undefined` upon success.

If `path` refers to a symbolic link, then the link is removed without affecting
the file or directory to which that link refers. If the `path`refers to a file
path that is not a symbolic link, the file is deleted. See the POSIX [unlink(2)](http://man7.org/linux/man-pages/man2/unlink.2.html) documentation for more detail.

#### fsPromises.utimes(path, atime, mtime)#

Added in: v10.0.0
- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `atime`[<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Date>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Date)
- `mtime`[<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Date>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Date)
- Returns: [<Promise>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Promise) Fulfills with`undefined` upon success.

Change the file system timestamps of the object referenced by `path`.

The `atime` and `mtime` arguments follow these rules:

- Values can be either numbers representing Unix epoch time, `Date`s, or a
numeric string like `'123456789.0'`.
- If the value can not be converted to a number, or is `NaN`, `Infinity`, or `-Infinity`, an `Error` will be thrown.

#### fsPromises.watch(filename[, options])#

Added in: v15.9.0, v14.18.0
- `filename`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `options`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `persistent`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) Indicates whether the process should continue to run
as long as files are being watched.**Default:**`true`.
  - `recursive`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) Indicates whether all subdirectories should be
watched, or only the current directory. This applies when a directory is
specified, and only on supported platforms (See[caveats](#caveats)). **Default:**`false`.
  - `encoding`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) Specifies the character encoding to be used for the
filename passed to the listener.**Default:**`'utf8'`.
  - `signal`[<AbortSignal>](https://nodejs.org/api/globals.html#class-abortsignal) An [<AbortSignal>](https://nodejs.org/api/globals.html#class-abortsignal) used to signal when the watcher
should stop.
  - `maxQueue`[<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) Specifies the number of events to queue between iterations
of the [<AsyncIterator>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/AsyncIterator) returned.**Default:**`2048`.
  - `overflow`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) Either`'ignore'` or `'throw'` when there are more events to be
queued than `maxQueue` allows. `'ignore'` means overflow events are dropped and a
warning is emitted, while `'throw'` means to throw an exception. **Default:**`'ignore'`.
  - `ignore`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<RegExp>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/RegExp) | [<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function) | [<Array>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Array) Pattern(s) to ignore. Strings are
glob patterns (using[minimatch](https://github.com/isaacs/minimatch)), RegExp patterns are tested against
the filename, and functions receive the filename and return `true` to
ignore. **Default:**`undefined`.

- Returns: [<AsyncIterator>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/AsyncIterator) of objects with the properties:
  - `eventType`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) The type of change
  - `filename`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<null>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#null_type) The name of the file changed.

Returns an async iterator that watches for changes on `filename`, where `filename` is either a file or a directory.

```js
const { watch } = require('node:fs/promises');

const ac = new AbortController();
const { signal } = ac;
setTimeout(() => ac.abort(), 10000);

(async () => {
  try {
    const watcher = watch(__filename, { signal });
    for await (const event of watcher)
      console.log(event);
  } catch (err) {
    if (err.name === 'AbortError')
      return;
    throw err;
  }
})();
jscopy
```

On most platforms, `'rename'` is emitted whenever a filename appears or
disappears in the directory.

All the [caveats](#caveats) for `fs.watch()` also apply to `fsPromises.watch()`.

#### fsPromises.writeFile(file, data[, options])#

Added in: v10.0.0
**History**

| Version | Changes |
| --- | --- |
| v21.0.0, v20.10.0 | The `flush` option is now supported. |
| v15.14.0, v14.18.0 | The `data` argument supports `AsyncIterable`, `Iterable`, and `Stream`. |
| v15.2.0, v14.17.0 | The options argument may include an AbortSignal to abort an ongoing writeFile request. |
| v14.0.0 | The `data` parameter won't coerce unsupported input to strings anymore. |

- `file`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api) | [<FileHandle>](https://nodejs.org/api/fs.html#class-filehandle) filename or`FileHandle`
- `data`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<TypedArray>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/TypedArray) | [<DataView>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/DataView) | [<AsyncIterable>](https://tc39.github.io/ecma262/#sec-asynciterable-interface) | [<Stream>](https://nodejs.org/api/stream.html#stream)
- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object) | [<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type)
  - `encoding`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<null>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#null_type)**Default:**`'utf8'`
  - `mode`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)**Default:**`0o666`
  - `flag`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) See[support of file system flags](#file-system-flags). **Default:**`'w'`.
  - `flush`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) If all data is successfully written to the file, and`flush` is `true`, `filehandle.sync()` is used to flush the data. **Default:**`false`.
  - `signal`[<AbortSignal>](https://nodejs.org/api/globals.html#class-abortsignal) allows aborting an in-progress writeFile

- Returns: [<Promise>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Promise) Fulfills with`undefined` upon success.

Asynchronously writes data to a file, replacing the file if it already exists. `data`can be a string, a buffer, an [<AsyncIterable>](https://tc39.github.io/ecma262/#sec-asynciterable-interface), or an {Iterable} object.

The `encoding` option is ignored if `data` is a buffer.

If `options` is a string, then it specifies the encoding.

The `mode` option only affects the newly created file. See [fs.open()](#fsopenpath-flags-mode-callback) for more details.

Any specified [<FileHandle>](https://nodejs.org/api/fs.html#class-filehandle) has to support writing.

It is unsafe to use `fsPromises.writeFile()` multiple times on the same file
without waiting for the promise to be settled.

Similarly to `fsPromises.readFile` - `fsPromises.writeFile` is a convenience
method that performs multiple `write` calls internally to write the buffer
passed to it. For performance sensitive code consider using [fs.createWriteStream()](#fscreatewritestreampath-options) or [filehandle.createWriteStream()](#filehandlecreatewritestreamoptions).

It is possible to use an [<AbortSignal>](https://nodejs.org/api/globals.html#class-abortsignal) to cancel an`fsPromises.writeFile()`.
Cancelation is "best effort", and some amount of data is likely still
to be written.

```mjs
import { writeFile } from 'node:fs/promises';
import { Buffer } from 'node:buffer';

try {
  const controller = new AbortController();
  const { signal } = controller;
  const data = new Uint8Array(Buffer.from('Hello Node.js'));
  const promise = writeFile('message.txt', data, { signal });

  // Abort the request before the promise settles.
  controller.abort();

  await promise;
} catch (err) {
  // When a request is aborted - err is an AbortError
  console.error(err);
}
mjscopy
```

Aborting an ongoing request does not abort individual operating
system requests but rather the internal buffering `fs.writeFile` performs.

#### fsPromises.constants#

Added in: v18.4.0, v16.17.0
- Type: [<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)

Returns an object containing commonly used constants for file system
operations. The object is the same as `fs.constants`. See [FS constants](#fs-constants) for more details.

### Callback API#

The callback APIs perform all operations asynchronously, without blocking the
event loop, then invoke a callback function upon completion or error.

The callback APIs use the underlying Node.js threadpool to perform file
system operations off the event loop thread. These operations are not
synchronized or threadsafe. Care must be taken when performing multiple
concurrent modifications on the same file or data corruption may occur.

#### fs.access(path[, mode], callback)#

Added in: v0.11.15
**History**

| Version | Changes |
| --- | --- |
| v25.0.0 | The constants `fs.F_OK`, `fs.R_OK`, `fs.W_OK` and `fs.X_OK` which were present directly on `fs` are removed. |
| v20.8.0 | The constants `fs.F_OK`, `fs.R_OK`, `fs.W_OK` and `fs.X_OK` which were present directly on `fs` are deprecated. |
| v18.0.0 | Passing an invalid callback to the `callback` argument now throws `ERR_INVALID_ARG_TYPE` instead of `ERR_INVALID_CALLBACK`. |
| v7.6.0 | The `path` parameter can be a WHATWG `URL` object using `file:` protocol. |
| v6.3.0 | The constants like `fs.R_OK`, etc which were present directly on `fs` were moved into `fs.constants` as a soft deprecation. Thus for Node.js `< v6.3.0` use `fs` to access those constants, or do something like `(fs.constants \|\| fs).R_OK` to work with all versions. |

- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `mode`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)**Default:**`fs.constants.F_OK`
- `callback`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function)
  - `err`[<Error>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Error)

Tests a user's permissions for the file or directory specified by `path`.
The `mode` argument is an optional integer that specifies the accessibility
checks to be performed. `mode` should be either the value `fs.constants.F_OK` or a mask consisting of the bitwise OR of any of `fs.constants.R_OK`, `fs.constants.W_OK`, and `fs.constants.X_OK` (e.g. `fs.constants.W_OK | fs.constants.R_OK`). Check [File access constants](#file-access-constants) for
possible values of `mode`.

The final argument, `callback`, is a callback function that is invoked with
a possible error argument. If any of the accessibility checks fail, the error
argument will be an `Error` object. The following examples check if `package.json` exists, and if it is readable or writable.

```mjs
import { access, constants } from 'node:fs';

const file = 'package.json';

// Check if the file exists in the current directory.
access(file, constants.F_OK, (err) => {
  console.log(`${file} ${err ? 'does not exist' : 'exists'}`);
});

// Check if the file is readable.
access(file, constants.R_OK, (err) => {
  console.log(`${file} ${err ? 'is not readable' : 'is readable'}`);
});

// Check if the file is writable.
access(file, constants.W_OK, (err) => {
  console.log(`${file} ${err ? 'is not writable' : 'is writable'}`);
});

// Check if the file is readable and writable.
access(file, constants.R_OK | constants.W_OK, (err) => {
  console.log(`${file} ${err ? 'is not' : 'is'} readable and writable`);
});
mjscopy
```

Do not use `fs.access()` to check for the accessibility of a file before calling `fs.open()`, `fs.readFile()`, or `fs.writeFile()`. Doing
so introduces a race condition, since other processes may change the file's
state between the two calls. Instead, user code should open/read/write the
file directly and handle the error raised if the file is not accessible.

**write (NOT RECOMMENDED)**

```mjs
import { access, open, close } from 'node:fs';

access('myfile', (err) => {
  if (!err) {
    console.error('myfile already exists');
    return;
  }

  open('myfile', 'wx', (err, fd) => {
    if (err) throw err;

    try {
      writeMyData(fd);
    } finally {
      close(fd, (err) => {
        if (err) throw err;
      });
    }
  });
});
mjscopy
```

**write (RECOMMENDED)**

```mjs
import { open, close } from 'node:fs';

open('myfile', 'wx', (err, fd) => {
  if (err) {
    if (err.code === 'EEXIST') {
      console.error('myfile already exists');
      return;
    }

    throw err;
  }

  try {
    writeMyData(fd);
  } finally {
    close(fd, (err) => {
      if (err) throw err;
    });
  }
});
mjscopy
```

**read (NOT RECOMMENDED)**

```mjs
import { access, open, close } from 'node:fs';
access('myfile', (err) => {
  if (err) {
    if (err.code === 'ENOENT') {
      console.error('myfile does not exist');
      return;
    }

    throw err;
  }

  open('myfile', 'r', (err, fd) => {
    if (err) throw err;

    try {
      readMyData(fd);
    } finally {
      close(fd, (err) => {
        if (err) throw err;
      });
    }
  });
});
mjscopy
```

**read (RECOMMENDED)**

```mjs
import { open, close } from 'node:fs';

open('myfile', 'r', (err, fd) => {
  if (err) {
    if (err.code === 'ENOENT') {
      console.error('myfile does not exist');
      return;
    }

    throw err;
  }

  try {
    readMyData(fd);
  } finally {
    close(fd, (err) => {
      if (err) throw err;
    });
  }
});
mjscopy
```

The "not recommended" examples above check for accessibility and then use the
file; the "recommended" examples are better because they use the file directly
and handle the error, if any.

In general, check for the accessibility of a file only if the file will not be
used directly, for example when its accessibility is a signal from another
process.

On Windows, access-control policies (ACLs) on a directory may limit access to
a file or directory. The `fs.access()` function, however, does not check the
ACL and therefore may report that a path is accessible even if the ACL restricts
the user from reading or writing to it.

#### fs.appendFile(path, data[, options], callback)#

Added in: v0.6.7
**History**

| Version | Changes |
| --- | --- |
| v21.1.0, v20.10.0 | The `flush` option is now supported. |
| v18.0.0 | Passing an invalid callback to the `callback` argument now throws `ERR_INVALID_ARG_TYPE` instead of `ERR_INVALID_CALLBACK`. |
| v10.0.0 | The `callback` parameter is no longer optional. Not passing it will throw a `TypeError` at runtime. |
| v7.0.0 | The `callback` parameter is no longer optional. Not passing it will emit a deprecation warning with id DEP0013. |
| v7.0.0 | The passed `options` object will never be modified. |
| v5.0.0 | The `file` parameter can be a file descriptor now. |

- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api) | [<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) filename or file descriptor
- `data`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer)
- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object) | [<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type)
  - `encoding`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<null>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#null_type)**Default:**`'utf8'`
  - `mode`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)**Default:**`0o666`
  - `flag`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) See[support of file system flags](#file-system-flags). **Default:**`'a'`.
  - `flush`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) If`true`, the underlying file descriptor is flushed
prior to closing it. **Default:**`false`.

- `callback`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function)
  - `err`[<Error>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Error)

Asynchronously append data to a file, creating the file if it does not yet
exist. `data`can be a string or a [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer).

The `mode` option only affects the newly created file. See [fs.open()](#fsopenpath-flags-mode-callback) for more details.

```mjs
import { appendFile } from 'node:fs';

appendFile('message.txt', 'data to append', (err) => {
  if (err) throw err;
  console.log('The "data to append" was appended to file!');
});
mjscopy
```

If `options` is a string, then it specifies the encoding:

```mjs
import { appendFile } from 'node:fs';

appendFile('message.txt', 'data to append', 'utf8', callback);
mjscopy
```

The `path` may be specified as a numeric file descriptor that has been opened
for appending (using `fs.open()` or `fs.openSync()`). The file descriptor will
not be closed automatically.

```mjs
import { open, close, appendFile } from 'node:fs';

function closeFd(fd) {
  close(fd, (err) => {
    if (err) throw err;
  });
}

open('message.txt', 'a', (err, fd) => {
  if (err) throw err;

  try {
    appendFile(fd, 'data to append', 'utf8', (err) => {
      closeFd(fd);
      if (err) throw err;
    });
  } catch (err) {
    closeFd(fd);
    throw err;
  }
});
mjscopy
```

#### fs.chmod(path, mode, callback)#

Added in: v0.1.30
**History**

| Version | Changes |
| --- | --- |
| v18.0.0 | Passing an invalid callback to the `callback` argument now throws `ERR_INVALID_ARG_TYPE` instead of `ERR_INVALID_CALLBACK`. |
| v10.0.0 | The `callback` parameter is no longer optional. Not passing it will throw a `TypeError` at runtime. |
| v7.6.0 | The `path` parameter can be a WHATWG `URL` object using `file:` protocol. |
| v7.0.0 | The `callback` parameter is no longer optional. Not passing it will emit a deprecation warning with id DEP0013. |

- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `mode`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
- `callback`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function)
  - `err`[<Error>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Error)

Asynchronously changes the permissions of a file. No arguments other than a
possible exception are given to the completion callback.

See the POSIX [chmod(2)](http://man7.org/linux/man-pages/man2/chmod.2.html) documentation for more detail.

```mjs
import { chmod } from 'node:fs';

chmod('my_file.txt', 0o775, (err) => {
  if (err) throw err;
  console.log('The permissions for file "my_file.txt" have been changed!');
});
mjscopy
```

#### File modes#

The `mode` argument used in both the `fs.chmod()` and `fs.chmodSync()` methods is a numeric bitmask created using a logical OR of the following
constants:

| Constant | Octal | Description |
| --- | --- | --- |
| `fs.constants.S_IRUSR` | `0o400` | read by owner |
| `fs.constants.S_IWUSR` | `0o200` | write by owner |
| `fs.constants.S_IXUSR` | `0o100` | execute/search by owner |
| `fs.constants.S_IRGRP` | `0o40` | read by group |
| `fs.constants.S_IWGRP` | `0o20` | write by group |
| `fs.constants.S_IXGRP` | `0o10` | execute/search by group |
| `fs.constants.S_IROTH` | `0o4` | read by others |
| `fs.constants.S_IWOTH` | `0o2` | write by others |
| `fs.constants.S_IXOTH` | `0o1` | execute/search by others |

An easier method of constructing the `mode` is to use a sequence of three
octal digits (e.g. `765`). The left-most digit (`7` in the example), specifies
the permissions for the file owner. The middle digit (`6` in the example),
specifies permissions for the group. The right-most digit (`5` in the example),
specifies the permissions for others.

| Number | Description |
| --- | --- |
| `7` | read, write, and execute |
| `6` | read and write |
| `5` | read and execute |
| `4` | read only |
| `3` | write and execute |
| `2` | write only |
| `1` | execute only |
| `0` | no permission |

For example, the octal value `0o765` means:

- The owner may read, write, and execute the file.
- The group may read and write the file.
- Others may read and execute the file.

When using raw numbers where file modes are expected, any value larger than `0o777` may result in platform-specific behaviors that are not supported to work
consistently. Therefore constants like `S_ISVTX`, `S_ISGID`, or `S_ISUID` are
not exposed in `fs.constants`.

Caveats: on Windows only the write permission can be changed, and the
distinction among the permissions of group, owner, or others is not
implemented.

#### fs.chown(path, uid, gid, callback)#

Added in: v0.1.97
**History**

| Version | Changes |
| --- | --- |
| v18.0.0 | Passing an invalid callback to the `callback` argument now throws `ERR_INVALID_ARG_TYPE` instead of `ERR_INVALID_CALLBACK`. |
| v10.0.0 | The `callback` parameter is no longer optional. Not passing it will throw a `TypeError` at runtime. |
| v7.6.0 | The `path` parameter can be a WHATWG `URL` object using `file:` protocol. |
| v7.0.0 | The `callback` parameter is no longer optional. Not passing it will emit a deprecation warning with id DEP0013. |

- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `uid`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
- `gid`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
- `callback`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function)
  - `err`[<Error>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Error)

Asynchronously changes owner and group of a file. No arguments other than a
possible exception are given to the completion callback.

See the POSIX [chown(2)](http://man7.org/linux/man-pages/man2/chown.2.html) documentation for more detail.

#### fs.close(fd[, callback])#

Added in: v0.0.2
**History**

| Version | Changes |
| --- | --- |
| v18.0.0 | Passing an invalid callback to the `callback` argument now throws `ERR_INVALID_ARG_TYPE` instead of `ERR_INVALID_CALLBACK`. |
| v15.9.0, v14.17.0 | A default callback is now used if one is not provided. |
| v10.0.0 | The `callback` parameter is no longer optional. Not passing it will throw a `TypeError` at runtime. |
| v7.0.0 | The `callback` parameter is no longer optional. Not passing it will emit a deprecation warning with id DEP0013. |

- `fd`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
- `callback`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function)
  - `err`[<Error>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Error)

Closes the file descriptor. No arguments other than a possible exception are
given to the completion callback.

Calling `fs.close()` on any file descriptor (`fd`) that is currently in use
through any other `fs` operation may lead to undefined behavior.

See the POSIX [close(2)](http://man7.org/linux/man-pages/man2/close.2.html) documentation for more detail.

#### fs.copyFile(src, dest[, mode], callback)#

Added in: v8.5.0
**History**

| Version | Changes |
| --- | --- |
| v18.0.0 | Passing an invalid callback to the `callback` argument now throws `ERR_INVALID_ARG_TYPE` instead of `ERR_INVALID_CALLBACK`. |
| v14.0.0 | Changed `flags` argument to `mode` and imposed stricter type validation. |

- `src`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api) source filename to copy
- `dest`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api) destination filename of the copy operation
- `mode`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) modifiers for copy operation.**Default:**`0`.
- `callback`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function)
  - `err`[<Error>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Error)

Asynchronously copies `src` to `dest`. By default, `dest` is overwritten if it
already exists. No arguments other than a possible exception are given to the
callback function. Node.js makes no guarantees about the atomicity of the copy
operation. If an error occurs after the destination file has been opened for
writing, Node.js will attempt to remove the destination.

`mode` is an optional integer that specifies the behavior
of the copy operation. It is possible to create a mask consisting of the bitwise
OR of two or more values (e.g. `fs.constants.COPYFILE_EXCL | fs.constants.COPYFILE_FICLONE`).

- `fs.constants.COPYFILE_EXCL`: The copy operation will fail if `dest` already
exists.
- `fs.constants.COPYFILE_FICLONE`: The copy operation will attempt to create a
copy-on-write reflink. If the platform does not support copy-on-write, then a
fallback copy mechanism is used.
- `fs.constants.COPYFILE_FICLONE_FORCE`: The copy operation will attempt to
create a copy-on-write reflink. If the platform does not support
copy-on-write, then the operation will fail.

```mjs
import { copyFile, constants } from 'node:fs';

function callback(err) {
  if (err) throw err;
  console.log('source.txt was copied to destination.txt');
}

// destination.txt will be created or overwritten by default.
copyFile('source.txt', 'destination.txt', callback);

// By using COPYFILE_EXCL, the operation will fail if destination.txt exists.
copyFile('source.txt', 'destination.txt', constants.COPYFILE_EXCL, callback);
mjscopy
```

#### fs.cp(src, dest[, options], callback)#

Added in: v16.7.0
**History**

| Version | Changes |
| --- | --- |
| v22.3.0 | This API is no longer experimental. |
| v20.1.0, v18.17.0 | Accept an additional `mode` option to specify the copy behavior as the `mode` argument of `fs.copyFile()`. |
| v18.0.0 | Passing an invalid callback to the `callback` argument now throws `ERR_INVALID_ARG_TYPE` instead of `ERR_INVALID_CALLBACK`. |
| v17.6.0, v16.15.0 | Accepts an additional `verbatimSymlinks` option to specify whether to perform path resolution for symlinks. |

- `src`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api) source path to copy.
- `dest`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api) destination path to copy to.
- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `dereference`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) dereference symlinks.**Default:**`false`.
  - `errorOnExist`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) when`force` is `false`, and the destination
exists, throw an error. **Default:**`false`.
  - `filter`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function) Function to filter copied files/directories. Return`true` to copy the item, `false` to ignore it. When ignoring a directory,
all of its contents will be skipped as well. Can also return a `Promise` that fulfills with `true` or `false`. **Default:**`undefined`.
    - `src`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) source path to copy.
    - `dest`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) destination path to copy to.
    - Returns: [<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) | [<Promise>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Promise) A value that is coercible to`boolean` or
a `Promise` that fulfils with such value.

  - `force`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) overwrite existing file or directory. The copy
operation will ignore errors if you set this to false and the destination
exists. Use the`errorOnExist` option to change this behavior. **Default:**`true`.
  - `mode`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) modifiers for copy operation.**Default:**`0`.
See `mode` flag of [fs.copyFile()](#fscopyfilesrc-dest-mode-callback).
  - `preserveTimestamps`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) When`true` timestamps from `src` will
be preserved. **Default:**`false`.
  - `recursive`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) copy directories recursively**Default:**`false`
  - `verbatimSymlinks`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) When`true`, path resolution for symlinks will
be skipped. **Default:**`false`

- `callback`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function)
  - `err`[<Error>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Error)

Asynchronously copies the entire directory structure from `src` to `dest`,
including subdirectories and files.

When copying a directory to another directory, globs are not supported and
behavior is similar to `cp dir1/ dir2/`.

#### fs.createReadStream(path[, options])#

Added in: v0.1.31
**History**

| Version | Changes |
| --- | --- |
| v16.10.0 | The `fs` option does not need `open` method if an `fd` was provided. |
| v16.10.0 | The `fs` option does not need `close` method if `autoClose` is `false`. |
| v15.5.0 | Add support for `AbortSignal`. |
| v15.4.0 | The `fd` option accepts FileHandle arguments. |
| v14.0.0 | Change `emitClose` default to `true`. |
| v13.6.0, v12.17.0 | The `fs` options allow overriding the used `fs` implementation. |
| v12.10.0 | Enable `emitClose` option. |
| v11.0.0 | Impose new restrictions on `start` and `end`, throwing more appropriate errors in cases when we cannot reasonably handle the input values. |
| v7.6.0 | The `path` parameter can be a WHATWG `URL` object using `file:` protocol. |
| v7.0.0 | The passed `options` object will never be modified. |
| v2.3.0 | The passed `options` object can be a string now. |

- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `options`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `flags`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) See[support of file system flags](#file-system-flags). **Default:**`'r'`.
  - `encoding`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type)**Default:**`null`
  - `fd`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<FileHandle>](https://nodejs.org/api/fs.html#class-filehandle)**Default:**`null`
  - `mode`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)**Default:**`0o666`
  - `autoClose`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type)**Default:**`true`
  - `emitClose`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type)**Default:**`true`
  - `start`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
  - `end`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)**Default:**`Infinity`
  - `highWaterMark`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)**Default:**`64 * 1024`
  - `fs`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object) | [<null>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#null_type)**Default:**`null`
  - `signal`[<AbortSignal>](https://nodejs.org/api/globals.html#class-abortsignal) | [<null>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#null_type)**Default:**`null`

- Returns: [<fs.ReadStream>](https://nodejs.org/api/fs.html#class-fsreadstream)

`options` can include `start` and `end` values to read a range of bytes from
the file instead of the entire file. Both `start` and `end` are inclusive and
start counting at 0, allowed values are in the
[0, [Number.MAX_SAFE_INTEGER](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Number/MAX_SAFE_INTEGER)] range. If `fd` is specified and `start` is
omitted or `undefined`, `fs.createReadStream()` reads sequentially from the
current file position. The `encoding`can be any one of those accepted by [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer).

If `fd` is specified, `ReadStream` will ignore the `path` argument and will use
the specified file descriptor. This means that no `'open'` event will be
emitted. `fd` should be blocking; non-blocking `fd`s should be passed to [<net.Socket>](https://nodejs.org/api/net.html#class-netsocket).

If `fd` points to a character device that only supports blocking reads
(such as keyboard or sound card), read operations do not finish until data is
available. This can prevent the process from exiting and the stream from
closing naturally.

By default, the stream will emit a `'close'` event after it has been
destroyed. Set the `emitClose` option to `false` to change this behavior.

By providing the `fs` option, it is possible to override the corresponding `fs` implementations for `open`, `read`, and `close`. When providing the `fs` option,
an override for `read` is required. If no `fd` is provided, an override for `open` is also required. If `autoClose` is `true`, an override for `close` is
also required.

```mjs
import { createReadStream } from 'node:fs';

// Create a stream from some character device.
const stream = createReadStream('/dev/input/event0');
setTimeout(() => {
  stream.close(); // This may not close the stream.
  // Artificially marking end-of-stream, as if the underlying resource had
  // indicated end-of-file by itself, allows the stream to close.
  // This does not cancel pending read operations, and if there is such an
  // operation, the process may still not be able to exit successfully
  // until it finishes.
  stream.push(null);
  stream.read(0);
}, 100);
mjscopy
```

If `autoClose` is false, then the file descriptor won't be closed, even if
there's an error. It is the application's responsibility to close it and make
sure there's no file descriptor leak. If `autoClose` is set to true (default
behavior), on `'error'` or `'end'` the file descriptor will be closed
automatically.

`mode` sets the file mode (permission and sticky bits), but only if the
file was created.

An example to read the last 10 bytes of a file which is 100 bytes long:

```mjs
import { createReadStream } from 'node:fs';

createReadStream('sample.txt', { start: 90, end: 99 });
mjscopy
```

If `options` is a string, then it specifies the encoding.

#### fs.createWriteStream(path[, options])#

Added in: v0.1.31
**History**

| Version | Changes |
| --- | --- |
| v21.0.0, v20.10.0 | The `flush` option is now supported. |
| v16.10.0 | The `fs` option does not need `open` method if an `fd` was provided. |
| v16.10.0 | The `fs` option does not need `close` method if `autoClose` is `false`. |
| v15.5.0 | Add support for `AbortSignal`. |
| v15.4.0 | The `fd` option accepts FileHandle arguments. |
| v14.0.0 | Change `emitClose` default to `true`. |
| v13.6.0, v12.17.0 | The `fs` options allow overriding the used `fs` implementation. |
| v12.10.0 | Enable `emitClose` option. |
| v7.6.0 | The `path` parameter can be a WHATWG `URL` object using `file:` protocol. |
| v7.0.0 | The passed `options` object will never be modified. |
| v5.5.0 | The `autoClose` option is supported now. |
| v2.3.0 | The passed `options` object can be a string now. |

- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `options`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `flags`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) See[support of file system flags](#file-system-flags). **Default:**`'w'`.
  - `encoding`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type)**Default:**`'utf8'`
  - `fd`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<FileHandle>](https://nodejs.org/api/fs.html#class-filehandle)**Default:**`null`
  - `mode`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)**Default:**`0o666`
  - `autoClose`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type)**Default:**`true`
  - `emitClose`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type)**Default:**`true`
  - `start`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
  - `fs`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object) | [<null>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#null_type)**Default:**`null`
  - `signal`[<AbortSignal>](https://nodejs.org/api/globals.html#class-abortsignal) | [<null>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#null_type)**Default:**`null`
  - `highWaterMark`[<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)**Default:**`16384`
  - `flush`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) If`true`, the underlying file descriptor is flushed
prior to closing it. **Default:**`false`.

- Returns: [<fs.WriteStream>](https://nodejs.org/api/fs.html#class-fswritestream)

`options` may also include a `start` option to allow writing data at some
position past the beginning of the file, allowed values are in the
[0, [Number.MAX_SAFE_INTEGER](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Number/MAX_SAFE_INTEGER)] range. Modifying a file rather than
replacing it may require the `flags` option to be set to `r+` rather than the
default `w`. The `encoding`can be any one of those accepted by [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer).

If `autoClose` is set to true (default behavior) on `'error'` or `'finish'` the file descriptor will be closed automatically. If `autoClose` is false,
then the file descriptor won't be closed, even if there's an error.
It is the application's responsibility to close it and make sure there's no
file descriptor leak.

By default, the stream will emit a `'close'` event after it has been
destroyed. Set the `emitClose` option to `false` to change this behavior.

By providing the `fs` option it is possible to override the corresponding `fs` implementations for `open`, `write`, `writev`, and `close`. Overriding `write()` without `writev()` can reduce performance as some optimizations (`_writev()`)
will be disabled. When providing the `fs` option, overrides for at least one of `write` and `writev` are required. If no `fd` option is supplied, an override
for `open` is also required. If `autoClose` is `true`, an override for `close` is also required.

Like [<fs.ReadStream>](https://nodejs.org/api/fs.html#class-fsreadstream), if`fd`is specified, [<fs.WriteStream>](https://nodejs.org/api/fs.html#class-fswritestream) will ignore the`path` argument and will use the specified file descriptor. This means that no `'open'` event will be emitted. `fd` should be blocking; non-blocking `fd`s
should be passed to [<net.Socket>](https://nodejs.org/api/net.html#class-netsocket).

If `options` is a string, then it specifies the encoding.

#### fs.exists(path, callback)#

Added in: v0.0.2Deprecated in: v1.0.0
**History**

| Version | Changes |
| --- | --- |
| v18.0.0 | Passing an invalid callback to the `callback` argument now throws `ERR_INVALID_ARG_TYPE` instead of `ERR_INVALID_CALLBACK`. |
| v7.6.0 | The `path` parameter can be a WHATWG `URL` object using `file:` protocol. |

Stability: 0 - Deprecated: Use [fs.stat()](#fsstatpath-options-callback) or [fs.access()](#fsaccesspath-mode-callback) instead.

- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `callback`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function)
  - `exists`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type)

Test whether or not the element at the given `path` exists by checking with the file system.
Then call the `callback` argument with either true or false:

```mjs
import { exists } from 'node:fs';

exists('/etc/passwd', (e) => {
  console.log(e ? 'it exists' : 'no passwd!');
});
mjscopy
```

**The parameters for this callback are not consistent with other Node.js
callbacks.** Normally, the first parameter to a Node.js callback is an `err` parameter, optionally followed by other parameters. The `fs.exists()` callback
has only one boolean parameter. This is one reason `fs.access()` is recommended
instead of `fs.exists()`.

If `path` is a symbolic link, it is followed. Thus, if `path` exists but points
to a non-existent element, the callback will receive the value `false`.

Using `fs.exists()` to check for the existence of a file before calling `fs.open()`, `fs.readFile()`, or `fs.writeFile()` is not recommended. Doing
so introduces a race condition, since other processes may change the file's
state between the two calls. Instead, user code should open/read/write the
file directly and handle the error raised if the file does not exist.

**write (NOT RECOMMENDED)**

```mjs
import { exists, open, close } from 'node:fs';

exists('myfile', (e) => {
  if (e) {
    console.error('myfile already exists');
  } else {
    open('myfile', 'wx', (err, fd) => {
      if (err) throw err;

      try {
        writeMyData(fd);
      } finally {
        close(fd, (err) => {
          if (err) throw err;
        });
      }
    });
  }
});
mjscopy
```

**write (RECOMMENDED)**

```mjs
import { open, close } from 'node:fs';
open('myfile', 'wx', (err, fd) => {
  if (err) {
    if (err.code === 'EEXIST') {
      console.error('myfile already exists');
      return;
    }

    throw err;
  }

  try {
    writeMyData(fd);
  } finally {
    close(fd, (err) => {
      if (err) throw err;
    });
  }
});
mjscopy
```

**read (NOT RECOMMENDED)**

```mjs
import { open, close, exists } from 'node:fs';

exists('myfile', (e) => {
  if (e) {
    open('myfile', 'r', (err, fd) => {
      if (err) throw err;

      try {
        readMyData(fd);
      } finally {
        close(fd, (err) => {
          if (err) throw err;
        });
      }
    });
  } else {
    console.error('myfile does not exist');
  }
});
mjscopy
```

**read (RECOMMENDED)**

```mjs
import { open, close } from 'node:fs';

open('myfile', 'r', (err, fd) => {
  if (err) {
    if (err.code === 'ENOENT') {
      console.error('myfile does not exist');
      return;
    }

    throw err;
  }

  try {
    readMyData(fd);
  } finally {
    close(fd, (err) => {
      if (err) throw err;
    });
  }
});
mjscopy
```

The "not recommended" examples above check for existence and then use the
file; the "recommended" examples are better because they use the file directly
and handle the error, if any.

In general, check for the existence of a file only if the file won't be
used directly, for example when its existence is a signal from another
process.

#### fs.fchmod(fd, mode, callback)#

Added in: v0.4.7
**History**

| Version | Changes |
| --- | --- |
| v18.0.0 | Passing an invalid callback to the `callback` argument now throws `ERR_INVALID_ARG_TYPE` instead of `ERR_INVALID_CALLBACK`. |
| v10.0.0 | The `callback` parameter is no longer optional. Not passing it will throw a `TypeError` at runtime. |
| v7.0.0 | The `callback` parameter is no longer optional. Not passing it will emit a deprecation warning with id DEP0013. |

- `fd`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
- `mode`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
- `callback`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function)
  - `err`[<Error>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Error)

Sets the permissions on the file. No arguments other than a possible exception
are given to the completion callback.

See the POSIX [fchmod(2)](http://man7.org/linux/man-pages/man2/fchmod.2.html) documentation for more detail.

#### fs.fchown(fd, uid, gid, callback)#

Added in: v0.4.7
**History**

| Version | Changes |
| --- | --- |
| v18.0.0 | Passing an invalid callback to the `callback` argument now throws `ERR_INVALID_ARG_TYPE` instead of `ERR_INVALID_CALLBACK`. |
| v10.0.0 | The `callback` parameter is no longer optional. Not passing it will throw a `TypeError` at runtime. |
| v7.0.0 | The `callback` parameter is no longer optional. Not passing it will emit a deprecation warning with id DEP0013. |

- `fd`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
- `uid`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
- `gid`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
- `callback`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function)
  - `err`[<Error>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Error)

Sets the owner of the file. No arguments other than a possible exception are
given to the completion callback.

See the POSIX [fchown(2)](http://man7.org/linux/man-pages/man2/fchown.2.html) documentation for more detail.

#### fs.fdatasync(fd, callback)#

Added in: v0.1.96
**History**

| Version | Changes |
| --- | --- |
| v18.0.0 | Passing an invalid callback to the `callback` argument now throws `ERR_INVALID_ARG_TYPE` instead of `ERR_INVALID_CALLBACK`. |
| v10.0.0 | The `callback` parameter is no longer optional. Not passing it will throw a `TypeError` at runtime. |
| v7.0.0 | The `callback` parameter is no longer optional. Not passing it will emit a deprecation warning with id DEP0013. |

- `fd`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
- `callback`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function)
  - `err`[<Error>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Error)

Forces all currently queued I/O operations associated with the file to the
operating system's synchronized I/O completion state. Refer to the POSIX [fdatasync(2)](http://man7.org/linux/man-pages/man2/fdatasync.2.html) documentation for details. No arguments other than a possible
exception are given to the completion callback.

#### fs.fstat(fd[, options], callback)#

Added in: v0.1.95
**History**

| Version | Changes |
| --- | --- |
| v18.0.0 | Passing an invalid callback to the `callback` argument now throws `ERR_INVALID_ARG_TYPE` instead of `ERR_INVALID_CALLBACK`. |
| v10.5.0 | Accepts an additional `options` object to specify whether the numeric values returned should be bigint. |
| v10.0.0 | The `callback` parameter is no longer optional. Not passing it will throw a `TypeError` at runtime. |
| v7.0.0 | The `callback` parameter is no longer optional. Not passing it will emit a deprecation warning with id DEP0013. |

- `fd`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `bigint`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) Whether the numeric values in the returned [<fs.Stats>](https://nodejs.org/api/fs.html#class-fsstats) object should be`bigint`. **Default:**`false`.

- `callback`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function)
  - `err`[<Error>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Error)
  - `stats`[<fs.Stats>](https://nodejs.org/api/fs.html#class-fsstats)

Invokes the callback with the [<fs.Stats>](https://nodejs.org/api/fs.html#class-fsstats) for the file descriptor.

See the POSIX [fstat(2)](http://man7.org/linux/man-pages/man2/fstat.2.html) documentation for more detail.

#### fs.fsync(fd, callback)#

Added in: v0.1.96
**History**

| Version | Changes |
| --- | --- |
| v18.0.0 | Passing an invalid callback to the `callback` argument now throws `ERR_INVALID_ARG_TYPE` instead of `ERR_INVALID_CALLBACK`. |
| v10.0.0 | The `callback` parameter is no longer optional. Not passing it will throw a `TypeError` at runtime. |
| v7.0.0 | The `callback` parameter is no longer optional. Not passing it will emit a deprecation warning with id DEP0013. |

- `fd`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
- `callback`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function)
  - `err`[<Error>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Error)

Request that all data for the open file descriptor is flushed to the storage
device. The specific implementation is operating system and device specific.
Refer to the POSIX [fsync(2)](http://man7.org/linux/man-pages/man2/fsync.2.html) documentation for more detail. No arguments other
than a possible exception are given to the completion callback.

#### fs.ftruncate(fd[, len], callback)#

Added in: v0.8.6
**History**

| Version | Changes |
| --- | --- |
| v18.0.0 | Passing an invalid callback to the `callback` argument now throws `ERR_INVALID_ARG_TYPE` instead of `ERR_INVALID_CALLBACK`. |
| v10.0.0 | The `callback` parameter is no longer optional. Not passing it will throw a `TypeError` at runtime. |
| v7.0.0 | The `callback` parameter is no longer optional. Not passing it will emit a deprecation warning with id DEP0013. |

- `fd`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
- `len`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)**Default:**`0`
- `callback`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function)
  - `err`[<Error>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Error)

Truncates the file descriptor. No arguments other than a possible exception are
given to the completion callback.

See the POSIX [ftruncate(2)](http://man7.org/linux/man-pages/man2/ftruncate.2.html) documentation for more detail.

If the file referred to by the file descriptor was larger than `len` bytes, only
the first `len` bytes will be retained in the file.

For example, the following program retains only the first four bytes of the
file:

```mjs
import { open, close, ftruncate } from 'node:fs';

function closeFd(fd) {
  close(fd, (err) => {
    if (err) throw err;
  });
}

open('temp.txt', 'r+', (err, fd) => {
  if (err) throw err;

  try {
    ftruncate(fd, 4, (err) => {
      closeFd(fd);
      if (err) throw err;
    });
  } catch (err) {
    closeFd(fd);
    if (err) throw err;
  }
});
mjscopy
```

If the file previously was shorter than `len` bytes, it is extended, and the
extended part is filled with null bytes (`'\0'`):

If `len` is negative then `0` will be used.

#### fs.futimes(fd, atime, mtime, callback)#

Added in: v0.4.2
**History**

| Version | Changes |
| --- | --- |
| v18.0.0 | Passing an invalid callback to the `callback` argument now throws `ERR_INVALID_ARG_TYPE` instead of `ERR_INVALID_CALLBACK`. |
| v10.0.0 | The `callback` parameter is no longer optional. Not passing it will throw a `TypeError` at runtime. |
| v7.0.0 | The `callback` parameter is no longer optional. Not passing it will emit a deprecation warning with id DEP0013. |
| v4.1.0 | Numeric strings, `NaN`, and `Infinity` are now allowed time specifiers. |

- `fd`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
- `atime`[<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Date>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Date)
- `mtime`[<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Date>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Date)
- `callback`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function)
  - `err`[<Error>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Error)

Change the file system timestamps of the object referenced by the supplied file
descriptor. See [fs.utimes()](#fsutimespath-atime-mtime-callback).

#### fs.glob(pattern[, options], callback)#

Added in: v22.0.0
**History**

| Version | Changes |
| --- | --- |
| v26.1.0 | Add support for the `followSymlinks` option. |
| v24.1.0, v22.17.0 | Add support for `URL` instances for `cwd` option. |
| v24.0.0, v22.17.0 | Marking the API stable. |
| v23.7.0, v22.14.0 | Add support for `exclude` option to accept glob patterns. |
| v22.2.0 | Add support for `withFileTypes` as an option. |

- `pattern`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<string[]>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type)

- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)

  - `cwd`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api) current working directory.**Default:**`process.cwd()`
  - `exclude`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function) | [<string[]>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) Function to filter out files/directories or a
list of glob patterns to be excluded. If a function is provided, return`true` to exclude the item, `false` to include it. **Default:**`undefined`.
  - `followSymlinks`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) When`true`, symbolic links to directories are
followed while expanding `**` patterns. **Default:**`false`.
  - `withFileTypes`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type)`true` if the glob should return paths as Dirents, `false` otherwise. **Default:**`false`.

- `callback`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function)

  - `err`[<Error>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Error)

- Retrieves the files matching the specified pattern.

When `followSymlinks` is enabled, detected symbolic link cycles are not
traversed recursively.

```mjs
import { glob } from 'node:fs';

glob('**/*.js', (err, matches) => {
  if (err) throw err;
  console.log(matches);
});
const { glob } = require('node:fs');

glob('**/*.js', (err, matches) => {
  if (err) throw err;
  console.log(matches);
});
javascriptcopy
```

#### fs.lchmod(path, mode, callback)#

Deprecated in: v0.4.7
**History**

| Version | Changes |
| --- | --- |
| v18.0.0 | Passing an invalid callback to the `callback` argument now throws `ERR_INVALID_ARG_TYPE` instead of `ERR_INVALID_CALLBACK`. |
| v16.0.0 | The error returned may be an `AggregateError` if more than one error is returned. |
| v10.0.0 | The `callback` parameter is no longer optional. Not passing it will throw a `TypeError` at runtime. |
| v7.0.0 | The `callback` parameter is no longer optional. Not passing it will emit a deprecation warning with id DEP0013. |

Stability: 0 - Deprecated

- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `mode`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
- `callback`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function)
  - `err`[<Error>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Error) | [<AggregateError>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/AggregateError)

Changes the permissions on a symbolic link. No arguments other than a possible
exception are given to the completion callback.

This method is only implemented on macOS.

See the POSIX [lchmod(2)](http://man7.org/linux/man-pages/man2/lchmod.2.html) documentation for more detail.

#### fs.lchown(path, uid, gid, callback)#

**History**

| Version | Changes |
| --- | --- |
| v18.0.0 | Passing an invalid callback to the `callback` argument now throws `ERR_INVALID_ARG_TYPE` instead of `ERR_INVALID_CALLBACK`. |
| v10.6.0 | This API is no longer deprecated. |
| v10.0.0 | The `callback` parameter is no longer optional. Not passing it will throw a `TypeError` at runtime. |
| v7.0.0 | The `callback` parameter is no longer optional. Not passing it will emit a deprecation warning with id DEP0013. |
| v0.4.7 | Documentation-only deprecation. |

- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `uid`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
- `gid`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
- `callback`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function)
  - `err`[<Error>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Error)

Set the owner of the symbolic link. No arguments other than a possible
exception are given to the completion callback.

See the POSIX [lchown(2)](http://man7.org/linux/man-pages/man2/lchown.2.html) documentation for more detail.

#### fs.lutimes(path, atime, mtime, callback)#

Added in: v14.5.0, v12.19.0
**History**

| Version | Changes |
| --- | --- |
| v18.0.0 | Passing an invalid callback to the `callback` argument now throws `ERR_INVALID_ARG_TYPE` instead of `ERR_INVALID_CALLBACK`. |

- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `atime`[<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Date>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Date)
- `mtime`[<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Date>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Date)
- `callback`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function)
  - `err`[<Error>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Error)

Changes the access and modification times of a file in the same way as [fs.utimes()](#fsutimespath-atime-mtime-callback), with the difference that if the path refers to a symbolic
link, then the link is not dereferenced: instead, the timestamps of the
symbolic link itself are changed.

No arguments other than a possible exception are given to the completion
callback.

#### fs.link(existingPath, newPath, callback)#

Added in: v0.1.31
**History**

| Version | Changes |
| --- | --- |
| v18.0.0 | Passing an invalid callback to the `callback` argument now throws `ERR_INVALID_ARG_TYPE` instead of `ERR_INVALID_CALLBACK`. |
| v10.0.0 | The `callback` parameter is no longer optional. Not passing it will throw a `TypeError` at runtime. |
| v7.6.0 | The `existingPath` and `newPath` parameters can be WHATWG `URL` objects using `file:` protocol. Support is currently still _experimental_. |
| v7.0.0 | The `callback` parameter is no longer optional. Not passing it will emit a deprecation warning with id DEP0013. |

- `existingPath`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `newPath`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `callback`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function)
  - `err`[<Error>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Error)

Creates a new link from the `existingPath` to the `newPath`. See the POSIX [link(2)](http://man7.org/linux/man-pages/man2/link.2.html) documentation for more detail. No arguments other than a possible
exception are given to the completion callback.

#### fs.lstat(path[, options], callback)#

Added in: v0.1.30
**History**

| Version | Changes |
| --- | --- |
| v18.0.0 | Passing an invalid callback to the `callback` argument now throws `ERR_INVALID_ARG_TYPE` instead of `ERR_INVALID_CALLBACK`. |
| v10.5.0 | Accepts an additional `options` object to specify whether the numeric values returned should be bigint. |
| v10.0.0 | The `callback` parameter is no longer optional. Not passing it will throw a `TypeError` at runtime. |
| v7.6.0 | The `path` parameter can be a WHATWG `URL` object using `file:` protocol. |
| v7.0.0 | The `callback` parameter is no longer optional. Not passing it will emit a deprecation warning with id DEP0013. |

- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `bigint`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) Whether the numeric values in the returned [<fs.Stats>](https://nodejs.org/api/fs.html#class-fsstats) object should be`bigint`. **Default:**`false`.

- `callback`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function)
  - `err`[<Error>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Error)
  - `stats`[<fs.Stats>](https://nodejs.org/api/fs.html#class-fsstats)

Retrieves the [<fs.Stats>](https://nodejs.org/api/fs.html#class-fsstats) for the symbolic link referred to by the path.
The callback gets two arguments`(err, stats)` where `stats`is a [<fs.Stats>](https://nodejs.org/api/fs.html#class-fsstats) object.`lstat()` is identical to `stat()`, except that if `path` is a symbolic
link, then the link itself is stat-ed, not the file that it refers to.

See the POSIX [lstat(2)](http://man7.org/linux/man-pages/man2/lstat.2.html) documentation for more details.

#### fs.mkdir(path[, options], callback)#

Added in: v0.1.8
**History**

| Version | Changes |
| --- | --- |
| v18.0.0 | Passing an invalid callback to the `callback` argument now throws `ERR_INVALID_ARG_TYPE` instead of `ERR_INVALID_CALLBACK`. |
| v13.11.0, v12.17.0 | In `recursive` mode, the callback now receives the first created path as an argument. |
| v10.12.0 | The second argument can now be an `options` object with `recursive` and `mode` properties. |
| v10.0.0 | The `callback` parameter is no longer optional. Not passing it will throw a `TypeError` at runtime. |
| v7.6.0 | The `path` parameter can be a WHATWG `URL` object using `file:` protocol. |
| v7.0.0 | The `callback` parameter is no longer optional. Not passing it will emit a deprecation warning with id DEP0013. |

- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object) | [<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
  - `recursive`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type)**Default:**`false`
  - `mode`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) Not supported on Windows. See[File modes](#file-modes) for more details. **Default:**`0o777`.

- `callback`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function)
  - `err`[<Error>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Error)
  - `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<undefined>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#undefined_type) Present only if a directory is created with`recursive` set to `true`.

Asynchronously creates a directory.

The callback is given a possible exception and, if `recursive` is `true`, the
first directory path created, `(err[, path])`. `path` can still be `undefined` when `recursive` is `true`, if no directory was
created (for instance, if it was previously created).

The optional `options` argument can be an integer specifying `mode` (permission
and sticky bits), or an object with a `mode` property and a `recursive` property indicating whether parent directories should be created. Calling `fs.mkdir()` when `path` is a directory that exists results in an error only
when `recursive` is false. If `recursive` is false and the directory exists,
an `EEXIST` error occurs.

```mjs
import { mkdir } from 'node:fs';

// Create ./tmp/a/apple, regardless of whether ./tmp and ./tmp/a exist.
mkdir('./tmp/a/apple', { recursive: true }, (err) => {
  if (err) throw err;
});
mjscopy
```

On Windows, using `fs.mkdir()` on the root directory even with recursion will
result in an error:

```mjs
import { mkdir } from 'node:fs';

mkdir('/', { recursive: true }, (err) => {
  // => [Error: EPERM: operation not permitted, mkdir 'C:\']
});
mjscopy
```

See the POSIX [mkdir(2)](http://man7.org/linux/man-pages/man2/mkdir.2.html) documentation for more details.

#### fs.mkdtemp(prefix[, options], callback)#

Added in: v5.10.0
**History**

| Version | Changes |
| --- | --- |
| v20.6.0, v18.19.0 | The `prefix` parameter now accepts buffers and URL. |
| v18.0.0 | Passing an invalid callback to the `callback` argument now throws `ERR_INVALID_ARG_TYPE` instead of `ERR_INVALID_CALLBACK`. |
| v16.5.0, v14.18.0 | The `prefix` parameter now accepts an empty string. |
| v10.0.0 | The `callback` parameter is no longer optional. Not passing it will throw a `TypeError` at runtime. |
| v7.0.0 | The `callback` parameter is no longer optional. Not passing it will emit a deprecation warning with id DEP0013. |
| v6.2.1 | The `callback` parameter is optional now. |

- `prefix`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `options`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `encoding`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type)**Default:**`'utf8'`

- `callback`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function)
  - `err`[<Error>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Error)
  - `directory`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type)

Creates a unique temporary directory.

Generates six random characters to be appended behind a required `prefix` to create a unique temporary directory. Due to platform
inconsistencies, avoid trailing `X` characters in `prefix`. Some platforms,
notably the BSDs, can return more than six random characters, and replace
trailing `X` characters in `prefix` with random characters.

The created directory path is passed as a string to the callback's second
parameter.

The optional `options` argument can be a string specifying an encoding, or an
object with an `encoding` property specifying the character encoding to use.

```mjs
import { mkdtemp } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

mkdtemp(join(tmpdir(), 'foo-'), (err, directory) => {
  if (err) throw err;
  console.log(directory);
  // Prints: /tmp/foo-itXde2 or C:\Users\...\AppData\Local\Temp\foo-itXde2
});
mjscopy
```

The `fs.mkdtemp()` method will append the six randomly selected characters
directly to the `prefix` string. For instance, given a directory `/tmp`, if the
intention is to create a temporary directory _within_`/tmp`, the `prefix` must end with a trailing platform-specific path separator
(`require('node:path').sep`).

```mjs
import { tmpdir } from 'node:os';
import { mkdtemp } from 'node:fs';

// The parent directory for the new temporary directory
const tmpDir = tmpdir();

// This method is *INCORRECT*:
mkdtemp(tmpDir, (err, directory) => {
  if (err) throw err;
  console.log(directory);
  // Will print something similar to `/tmpabc123`.
  // A new temporary directory is created at the file system root
  // rather than *within* the /tmp directory.
});

// This method is *CORRECT*:
import { sep } from 'node:path';
mkdtemp(`${tmpDir}${sep}`, (err, directory) => {
  if (err) throw err;
  console.log(directory);
  // Will print something similar to `/tmp/abc123`.
  // A new temporary directory is created within
  // the /tmp directory.
});
mjscopy
```

#### fs.open(path[, flags[, mode]], callback)#

Added in: v0.0.2
**History**

| Version | Changes |
| --- | --- |
| v18.0.0 | Passing an invalid callback to the `callback` argument now throws `ERR_INVALID_ARG_TYPE` instead of `ERR_INVALID_CALLBACK`. |
| v11.1.0 | The `flags` argument is now optional and defaults to `'r'`. |
| v9.9.0 | The `as` and `as+` flags are supported now. |
| v7.6.0 | The `path` parameter can be a WHATWG `URL` object using `file:` protocol. |

- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `flags`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) See[support of file system flags](#file-system-flags). **Default:**`'r'`.
- `mode`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)**Default:**`0o666` (readable and writable)
- `callback`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function)
  - `err`[<Error>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Error)
  - `fd`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)

Asynchronous file open. See the POSIX [open(2)](http://man7.org/linux/man-pages/man2/open.2.html) documentation for more details.

`mode` sets the file mode (permission and sticky bits), but only if the file was
created. On Windows, only the write permission can be manipulated; see [fs.chmod()](#fschmodpath-mode-callback).

The callback gets two arguments `(err, fd)`.

Some characters (`< > : " / \ | ? *`) are reserved under Windows as documented
by [Naming Files, Paths, and Namespaces](https://docs.microsoft.com/en-us/windows/desktop/FileIO/naming-a-file). Under NTFS, if the filename contains
a colon, Node.js will open a file system stream, as described by [this MSDN page](https://docs.microsoft.com/en-us/windows/desktop/FileIO/using-streams).

Functions based on `fs.open()` exhibit this behavior as well: `fs.writeFile()`, `fs.readFile()`, etc.

#### fs.openAsBlob(path[, options])#

Added in: v19.8.0
**History**

| Version | Changes |
| --- | --- |
| v24.0.0, v22.17.0 | Marking the API stable. |

- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `type`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) An optional mime type for the blob.

- Returns: [<Promise>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Promise) Fulfills with a [<Blob>](https://nodejs.org/api/buffer.html#class-blob) upon success.

Returns a [<Blob>](https://nodejs.org/api/buffer.html#class-blob) whose data is backed by the given file.

The file must not be modified after the [<Blob>](https://nodejs.org/api/buffer.html#class-blob) is created. Any modifications
will cause reading the [<Blob>](https://nodejs.org/api/buffer.html#class-blob) data to fail with a`DOMException` error.
Synchronous stat operations on the file when the `Blob` is created, and before
each read in order to detect whether the file data has been modified on disk.

```mjs
import { openAsBlob } from 'node:fs';

const blob = await openAsBlob('the.file.txt');
const ab = await blob.arrayBuffer();
blob.stream();
const { openAsBlob } = require('node:fs');

(async () => {
  const blob = await openAsBlob('the.file.txt');
  const ab = await blob.arrayBuffer();
  blob.stream();
})();
javascriptcopy
```

#### fs.opendir(path[, options], callback)#

Added in: v12.12.0
**History**

| Version | Changes |
| --- | --- |
| v20.1.0, v18.17.0 | Added `recursive` option. |
| v18.0.0 | Passing an invalid callback to the `callback` argument now throws `ERR_INVALID_ARG_TYPE` instead of `ERR_INVALID_CALLBACK`. |
| v13.1.0, v12.16.0 | The `bufferSize` option was introduced. |

- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `encoding`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<null>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#null_type)**Default:**`'utf8'`
  - `bufferSize`[<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) Number of directory entries that are buffered
internally when reading from the directory. Higher values lead to better
performance but higher memory usage.**Default:**`32`
  - `recursive`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type)**Default:**`false`

- `callback`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function)
  - `err`[<Error>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Error)
  - `dir`[<fs.Dir>](https://nodejs.org/api/fs.html#class-fsdir)

Asynchronously open a directory. See the POSIX [opendir(3)](http://man7.org/linux/man-pages/man3/opendir.3.html) documentation for
more details.

Creates an [<fs.Dir>](https://nodejs.org/api/fs.html#class-fsdir), which contains all further functions for reading from
and cleaning up the directory.

The `encoding` option sets the encoding for the `path` while opening the
directory and subsequent read operations.

#### fs.read(fd, buffer, offset, length, position, callback)#

Added in: v0.0.2
**History**

| Version | Changes |
| --- | --- |
| v18.0.0 | Passing an invalid callback to the `callback` argument now throws `ERR_INVALID_ARG_TYPE` instead of `ERR_INVALID_CALLBACK`. |
| v10.10.0 | The `buffer` parameter can now be any `TypedArray`, or a `DataView`. |
| v7.4.0 | The `buffer` parameter can now be a `Uint8Array`. |
| v6.0.0 | The `length` parameter can now be `0`. |

- `fd`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
- `buffer`[<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<TypedArray>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/TypedArray) | [<DataView>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/DataView) The buffer that the data will be
written to.
- `offset`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) The position in`buffer` to write the data to.
- `length`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) The number of bytes to read.
- `position`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<bigint>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#bigint_type) | [<null>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#null_type) Specifies where to begin reading from in the
file. If`position` is `null` or `-1`, data will be read from the current
file position, and the file position will be updated. If `position` is
a non-negative integer, the file position will be unchanged.
- `callback`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function)
  - `err`[<Error>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Error)
  - `bytesRead`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
  - `buffer`[<Buffer>](https://nodejs.org/api/buffer.html#class-buffer)

Read data from the file specified by `fd`.

The callback is given the three arguments, `(err, bytesRead, buffer)`.

If the file is not modified concurrently, the end-of-file is reached when the
number of bytes read is zero.

If this method is invoked as its [util.promisify()](https://nodejs.org/api/util.html#utilpromisifyoriginal)ed version, it returns
a promise for an `Object` with `bytesRead` and `buffer` properties.

The `fs.read()` method reads data from the file specified
by the file descriptor (`fd`).
The `length` argument indicates the maximum number
of bytes that Node.js
will attempt to read from the kernel.
However, the actual number of bytes read (`bytesRead`) can be lower
than the specified `length` for various reasons.

For example:

- If the file is shorter than the specified `length`, `bytesRead` will be set to the actual number of bytes read.
- If the file encounters EOF (End of File) before the buffer could
be filled, Node.js will read all available bytes until EOF is encountered,
and the `bytesRead` parameter in the callback will indicate
the actual number of bytes read, which may be less than the specified `length`.
- If the file is on a slow network `filesystem` or encounters any other issue during reading, `bytesRead` can be lower than the specified `length`.

Therefore, when using `fs.read()`, it's important to
check the `bytesRead` value to
determine how many bytes were actually read from the file.
Depending on your application
logic, you may need to handle cases where `bytesRead` is lower than the specified `length`,
such as by wrapping the read call in a loop if you require
a minimum amount of bytes.

This behavior is similar to the POSIX `preadv2` function.

#### fs.read(fd[, options], callback)#

Added in: v13.11.0, v12.17.0
**History**

| Version | Changes |
| --- | --- |
| v13.11.0, v12.17.0 | Options object can be passed in to make buffer, offset, length, and position optional. |

- `fd`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `buffer`[<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<TypedArray>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/TypedArray) | [<DataView>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/DataView)**Default:**`Buffer.alloc(16384)`
  - `offset`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)**Default:**`0`
  - `length`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)**Default:**`buffer.byteLength - offset`
  - `position`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<bigint>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#bigint_type) | [<null>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#null_type)**Default:**`null`

- `callback`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function)
  - `err`[<Error>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Error)
  - `bytesRead`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
  - `buffer`[<Buffer>](https://nodejs.org/api/buffer.html#class-buffer)

Similar to the [fs.read()](#fsreadfd-buffer-offset-length-position-callback) function, this version takes an optional `options` object. If no `options` object is specified, it will default with the
above values.

#### fs.read(fd, buffer[, options], callback)#

Added in: v18.2.0, v16.17.0
- `fd`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
- `buffer`[<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<TypedArray>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/TypedArray) | [<DataView>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/DataView) The buffer that the data will be
written to.
- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `offset`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)**Default:**`0`
  - `length`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)**Default:**`buffer.byteLength - offset`
  - `position`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<bigint>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#bigint_type)**Default:**`null`

- `callback`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function)
  - `err`[<Error>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Error)
  - `bytesRead`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
  - `buffer`[<Buffer>](https://nodejs.org/api/buffer.html#class-buffer)

Similar to the [fs.read()](#fsreadfd-buffer-offset-length-position-callback) function, this version takes an optional `options` object. If no `options` object is specified, it will default with the
above values.

#### fs.readdir(path[, options], callback)#

Added in: v0.1.8
**History**

| Version | Changes |
| --- | --- |
| v20.1.0, v18.17.0 | Added `recursive` option. |
| v18.0.0 | Passing an invalid callback to the `callback` argument now throws `ERR_INVALID_ARG_TYPE` instead of `ERR_INVALID_CALLBACK`. |
| v10.10.0 | New option `withFileTypes` was added. |
| v10.0.0 | The `callback` parameter is no longer optional. Not passing it will throw a `TypeError` at runtime. |
| v7.6.0 | The `path` parameter can be a WHATWG `URL` object using `file:` protocol. |
| v7.0.0 | The `callback` parameter is no longer optional. Not passing it will emit a deprecation warning with id DEP0013. |
| v6.0.0 | The `options` parameter was added. |

- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `options`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `encoding`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type)**Default:**`'utf8'`
  - `withFileTypes`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type)**Default:**`false`
  - `recursive`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) If`true`, reads the contents of a directory
recursively. In recursive mode, it will list all files, sub files and
directories. **Default:**`false`.

- `callback`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function)
  - `err`[<Error>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Error)
  - `files`[<string[]>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer[]>](buffer.html#class-buffer) | [<fs.Dirent[]>](fs.html#class-fsdirent)

Reads the contents of a directory. The callback gets two arguments `(err, files)` where `files` is an array of the names of the files in the directory excluding `'.'` and `'..'`.

See the POSIX [readdir(3)](http://man7.org/linux/man-pages/man3/readdir.3.html) documentation for more details.

The optional `options` argument can be a string specifying an encoding, or an
object with an `encoding` property specifying the character encoding to use for
the filenames passed to the callback. If the `encoding` is set to `'buffer'`,
the filenames returned will be passed as [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) objects.

If `options.withFileTypes` is set to `true`, the `files`array will contain [<fs.Dirent>](https://nodejs.org/api/fs.html#class-fsdirent) objects.

#### fs.readFile(path[, options], callback)#

Added in: v0.1.29
**History**

| Version | Changes |
| --- | --- |
| v18.0.0 | Passing an invalid callback to the `callback` argument now throws `ERR_INVALID_ARG_TYPE` instead of `ERR_INVALID_CALLBACK`. |
| v16.0.0 | The error returned may be an `AggregateError` if more than one error is returned. |
| v15.2.0, v14.17.0 | The options argument may include an AbortSignal to abort an ongoing readFile request. |
| v10.0.0 | The `callback` parameter is no longer optional. Not passing it will throw a `TypeError` at runtime. |
| v7.6.0 | The `path` parameter can be a WHATWG `URL` object using `file:` protocol. |
| v7.0.0 | The `callback` parameter is no longer optional. Not passing it will emit a deprecation warning with id DEP0013. |
| v5.1.0 | The `callback` will always be called with `null` as the `error` parameter in case of success. |
| v5.0.0 | The `path` parameter can be a file descriptor now. |

- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api) | [<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) filename or file descriptor
- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object) | [<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type)
  - `encoding`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<null>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#null_type)**Default:**`null`
  - `flag`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) See[support of file system flags](#file-system-flags). **Default:**`'r'`.
  - `signal`[<AbortSignal>](https://nodejs.org/api/globals.html#class-abortsignal) allows aborting an in-progress readFile

- `callback`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function)
  - `err`[<Error>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Error) | [<AggregateError>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/AggregateError)
  - `data`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer)

Asynchronously reads the entire contents of a file.

```mjs
import { readFile } from 'node:fs';

readFile('/etc/passwd', (err, data) => {
  if (err) throw err;
  console.log(data);
});
mjscopy
```

The callback is passed two arguments `(err, data)`, where `data` is the
contents of the file.

If no encoding is specified, then the raw buffer is returned.

If `options` is a string, then it specifies the encoding:

```mjs
import { readFile } from 'node:fs';

readFile('/etc/passwd', 'utf8', callback);
mjscopy
```

When the path is a directory, the behavior of `fs.readFile()` and [fs.readFileSync()](#fsreadfilesyncpath-options) is platform-specific. On macOS, Linux, and Windows, an
error will be returned. On FreeBSD, a representation of the directory's contents
will be returned.

```mjs
import { readFile } from 'node:fs';

// macOS, Linux, and Windows
readFile('<directory>', (err, data) => {
  // => [Error: EISDIR: illegal operation on a directory, read <directory>]
});

//  FreeBSD
readFile('<directory>', (err, data) => {
  // => null, <data>
});
mjscopy
```

It is possible to abort an ongoing request using an `AbortSignal`. If a
request is aborted the callback is called with an `AbortError`:

```mjs
import { readFile } from 'node:fs';

const controller = new AbortController();
const signal = controller.signal;
readFile(fileInfo[0].name, { signal }, (err, buf) => {
  // ...
});
// When you want to abort the request
controller.abort();
mjscopy
```

The `fs.readFile()` function buffers the entire file. To minimize memory costs,
when possible prefer streaming via `fs.createReadStream()`.

Aborting an ongoing request does not abort individual operating
system requests but rather the internal buffering `fs.readFile` performs.

#### File descriptors#

1. Any specified file descriptor has to support reading.
2. If a file descriptor is specified as the `path`, it will not be closed
automatically.
3. The reading will begin at the current position. For example, if the file
already had `'Hello World'` and six bytes are read with the file descriptor,
the call to `fs.readFile()` with the same file descriptor, would give `'World'`, rather than `'Hello World'`.

#### Performance Considerations#

The `fs.readFile()` method asynchronously reads the contents of a file into
memory one chunk at a time, allowing the event loop to turn between each chunk.
This allows the read operation to have less impact on other activity that may
be using the underlying libuv thread pool but means that it will take longer
to read a complete file into memory.

The additional read overhead can vary broadly on different systems and depends
on the type of file being read. If the file type is not a regular file (a pipe
for instance) and Node.js is unable to determine an actual file size, each read
operation will load on 64 KiB of data. For regular files, each read will process
512 KiB of data.

For applications that require as-fast-as-possible reading of file contents, it
is better to use `fs.read()` directly and for application code to manage
reading the full contents of the file itself.

The Node.js GitHub issue [#25741](https://github.com/nodejs/node/issues/25741) provides more information and a detailed
analysis on the performance of `fs.readFile()` for multiple file sizes in
different Node.js versions.

#### fs.readlink(path[, options], callback)#

Added in: v0.1.31
**History**

| Version | Changes |
| --- | --- |
| v18.0.0 | Passing an invalid callback to the `callback` argument now throws `ERR_INVALID_ARG_TYPE` instead of `ERR_INVALID_CALLBACK`. |
| v10.0.0 | The `callback` parameter is no longer optional. Not passing it will throw a `TypeError` at runtime. |
| v7.6.0 | The `path` parameter can be a WHATWG `URL` object using `file:` protocol. |
| v7.0.0 | The `callback` parameter is no longer optional. Not passing it will emit a deprecation warning with id DEP0013. |

- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `options`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `encoding`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type)**Default:**`'utf8'`

- `callback`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function)
  - `err`[<Error>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Error)
  - `linkString`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer)

Reads the contents of the symbolic link referred to by `path`. The callback gets
two arguments `(err, linkString)`.

See the POSIX [readlink(2)](http://man7.org/linux/man-pages/man2/readlink.2.html) documentation for more details.

The optional `options` argument can be a string specifying an encoding, or an
object with an `encoding` property specifying the character encoding to use for
the link path passed to the callback. If the `encoding` is set to `'buffer'`,
the link path returned will be passed as a [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) object.

#### fs.readv(fd, buffers[, position], callback)#

Added in: v13.13.0, v12.17.0
**History**

| Version | Changes |
| --- | --- |
| v18.0.0 | Passing an invalid callback to the `callback` argument now throws `ERR_INVALID_ARG_TYPE` instead of `ERR_INVALID_CALLBACK`. |

- `fd`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
- `buffers`{ArrayBufferView[]}
- `position`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<null>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#null_type)**Default:**`null`
- `callback`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function)
  - `err`[<Error>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Error)
  - `bytesRead`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
  - `buffers`{ArrayBufferView[]}

Read from a file specified by `fd` and write to an array of `ArrayBufferView`s
using `readv()`.

`position` is the offset from the beginning of the file from where data
should be read. If `typeof position !== 'number'`, the data will be read
from the current position.

The callback will be given three arguments: `err`, `bytesRead`, and `buffers`. `bytesRead` is how many bytes were read from the file.

If this method is invoked as its [util.promisify()](https://nodejs.org/api/util.html#utilpromisifyoriginal)ed version, it returns
a promise for an `Object` with `bytesRead` and `buffers` properties.

#### fs.realpath(path[, options], callback)#

Added in: v0.1.31
**History**

| Version | Changes |
| --- | --- |
| v18.0.0 | Passing an invalid callback to the `callback` argument now throws `ERR_INVALID_ARG_TYPE` instead of `ERR_INVALID_CALLBACK`. |
| v10.0.0 | The `callback` parameter is no longer optional. Not passing it will throw a `TypeError` at runtime. |
| v8.0.0 | Pipe/Socket resolve support was added. |
| v7.6.0 | The `path` parameter can be a WHATWG `URL` object using `file:` protocol. |
| v7.0.0 | The `callback` parameter is no longer optional. Not passing it will emit a deprecation warning with id DEP0013. |
| v6.4.0 | Calling `realpath` now works again for various edge cases on Windows. |
| v6.0.0 | The `cache` parameter was removed. |

- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `options`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `encoding`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type)**Default:**`'utf8'`

- `callback`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function)
  - `err`[<Error>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Error)
  - `resolvedPath`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer)

Asynchronously computes the canonical pathname by resolving `.`, `..`, and
symbolic links.

A canonical pathname is not necessarily unique. Hard links and bind mounts can
expose a file system entity through many pathnames.

This function behaves like [realpath(3)](http://man7.org/linux/man-pages/man3/realpath.3.html), with some exceptions:

1. No case conversion is performed on case-insensitive file systems.

2. The maximum number of symbolic links is platform-independent and generally
(much) higher than what the native [realpath(3)](http://man7.org/linux/man-pages/man3/realpath.3.html) implementation supports.

The `callback` gets two arguments `(err, resolvedPath)`. May use `process.cwd` to resolve relative paths.

Only paths that can be converted to UTF8 strings are supported.

The optional `options` argument can be a string specifying an encoding, or an
object with an `encoding` property specifying the character encoding to use for
the path passed to the callback. If the `encoding` is set to `'buffer'`,
the path returned will be passed as a [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) object.

If `path` resolves to a socket or a pipe, the function will return a system
dependent name for that object.

A path that does not exist results in an ENOENT error. `error.path` is the absolute file path.

#### fs.realpath.native(path[, options], callback)#

Added in: v9.2.0
**History**

| Version | Changes |
| --- | --- |
| v18.0.0 | Passing an invalid callback to the `callback` argument now throws `ERR_INVALID_ARG_TYPE` instead of `ERR_INVALID_CALLBACK`. |

- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `options`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `encoding`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type)**Default:**`'utf8'`

- `callback`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function)
  - `err`[<Error>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Error)
  - `resolvedPath`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer)

Asynchronous [realpath(3)](http://man7.org/linux/man-pages/man3/realpath.3.html).

The `callback` gets two arguments `(err, resolvedPath)`.

Only paths that can be converted to UTF8 strings are supported.

The optional `options` argument can be a string specifying an encoding, or an
object with an `encoding` property specifying the character encoding to use for
the path passed to the callback. If the `encoding` is set to `'buffer'`,
the path returned will be passed as a [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) object.

On Linux, when Node.js is linked against musl libc, the procfs file system must
be mounted on `/proc` in order for this function to work. Glibc does not have
this restriction.

#### fs.rename(oldPath, newPath, callback)#

Added in: v0.0.2
**History**

| Version | Changes |
| --- | --- |
| v18.0.0 | Passing an invalid callback to the `callback` argument now throws `ERR_INVALID_ARG_TYPE` instead of `ERR_INVALID_CALLBACK`. |
| v10.0.0 | The `callback` parameter is no longer optional. Not passing it will throw a `TypeError` at runtime. |
| v7.6.0 | The `oldPath` and `newPath` parameters can be WHATWG `URL` objects using `file:` protocol. Support is currently still _experimental_. |
| v7.0.0 | The `callback` parameter is no longer optional. Not passing it will emit a deprecation warning with id DEP0013. |

- `oldPath`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `newPath`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `callback`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function)
  - `err`[<Error>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Error)

Asynchronously rename file at `oldPath` to the pathname provided
as `newPath`. In the case that `newPath` already exists, it will
be overwritten. If there is a directory at `newPath`, an error will
be raised instead. No arguments other than a possible exception are
given to the completion callback.

See also: [rename(2)](http://man7.org/linux/man-pages/man2/rename.2.html).

```mjs
import { rename } from 'node:fs';

rename('oldFile.txt', 'newFile.txt', (err) => {
  if (err) throw err;
  console.log('Rename complete!');
});
mjscopy
```

#### fs.rmdir(path[, options], callback)#

Added in: v0.0.2
**History**

| Version | Changes |
| --- | --- |
| v25.0.0 | Remove `recursive` option. |
| v18.0.0 | Passing an invalid callback to the `callback` argument now throws `ERR_INVALID_ARG_TYPE` instead of `ERR_INVALID_CALLBACK`. |
| v16.0.0 | Using `fs.rmdir(path, { recursive: true })` on a `path` that is a file is no longer permitted and results in an `ENOENT` error on Windows and an `ENOTDIR` error on POSIX. |
| v16.0.0 | Using `fs.rmdir(path, { recursive: true })` on a `path` that does not exist is no longer permitted and results in a `ENOENT` error. |
| v16.0.0 | The `recursive` option is deprecated, using it triggers a deprecation warning. |
| v14.14.0 | The `recursive` option is deprecated, use `fs.rm` instead. |
| v13.3.0, v12.16.0 | The `maxBusyTries` option is renamed to `maxRetries`, and its default is 0. The `emfileWait` option has been removed, and `EMFILE` errors use the same retry logic as other errors. The `retryDelay` option is now supported. `ENFILE` errors are now retried. |
| v12.10.0 | The `recursive`, `maxBusyTries`, and `emfileWait` options are now supported. |
| v10.0.0 | The `callback` parameter is no longer optional. Not passing it will throw a `TypeError` at runtime. |
| v7.6.0 | The `path` parameters can be a WHATWG `URL` object using `file:` protocol. |
| v7.0.0 | The `callback` parameter is no longer optional. Not passing it will emit a deprecation warning with id DEP0013. |

- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object) There are currently no options exposed. There used to
be options for`recursive`, `maxBusyTries`, and `emfileWait` but they were
deprecated and removed. The `options` argument is still accepted for
backwards compatibility but it is not used.
- `callback`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function)
  - `err`[<Error>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Error)

Asynchronous [rmdir(2)](http://man7.org/linux/man-pages/man2/rmdir.2.html). No arguments other than a possible exception are given
to the completion callback.

Using `fs.rmdir()` on a file (not a directory) results in an `ENOENT` error on
Windows and an `ENOTDIR` error on POSIX.

To get a behavior similar to the `rm -rf` Unix command, use [fs.rm()](#fsrmpath-options-callback) with options `{ recursive: true, force: true }`.

#### fs.rm(path[, options], callback)#

Added in: v14.14.0
**History**

| Version | Changes |
| --- | --- |
| v17.3.0, v16.14.0 | The `path` parameter can be a WHATWG `URL` object using `file:` protocol. |

- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `force`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) When`true`, exceptions will be ignored if `path` does
not exist. **Default:**`false`.
  - `maxRetries`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) If an`EBUSY`, `EMFILE`, `ENFILE`, `ENOTEMPTY`, or `EPERM` error is encountered, Node.js will retry the operation with a linear
backoff wait of `retryDelay` milliseconds longer on each try. This option
represents the number of retries. This option is ignored if the `recursive` option is not `true`. **Default:**`0`.
  - `recursive`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) If`true`, perform a recursive removal. In
recursive mode operations are retried on failure. **Default:**`false`.
  - `retryDelay`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) The amount of time in milliseconds to wait between
retries. This option is ignored if the`recursive` option is not `true`. **Default:**`100`.

- `callback`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function)
  - `err`[<Error>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Error)

Asynchronously removes files and directories (modeled on the standard POSIX `rm` utility). No arguments other than a possible exception are given to the
completion callback.

#### fs.stat(path[, options], callback)#

Added in: v0.0.2
**History**

| Version | Changes |
| --- | --- |
| v25.7.0 | Accepts a `throwIfNoEntry` option to specify whether an exception should be thrown if the entry does not exist. |
| v18.0.0 | Passing an invalid callback to the `callback` argument now throws `ERR_INVALID_ARG_TYPE` instead of `ERR_INVALID_CALLBACK`. |
| v10.5.0 | Accepts an additional `options` object to specify whether the numeric values returned should be bigint. |
| v10.0.0 | The `callback` parameter is no longer optional. Not passing it will throw a `TypeError` at runtime. |
| v7.6.0 | The `path` parameter can be a WHATWG `URL` object using `file:` protocol. |
| v7.0.0 | The `callback` parameter is no longer optional. Not passing it will emit a deprecation warning with id DEP0013. |

- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `bigint`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) Whether the numeric values in the returned [<fs.Stats>](https://nodejs.org/api/fs.html#class-fsstats) object should be`bigint`. **Default:**`false`.
  - `throwIfNoEntry`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) Whether an exception will be thrown
if no file system entry exists, rather than returning`undefined`. **Default:**`true`.

- `callback`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function)
  - `err`[<Error>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Error)
  - `stats`[<fs.Stats>](https://nodejs.org/api/fs.html#class-fsstats)

Asynchronous [stat(2)](http://man7.org/linux/man-pages/man2/stat.2.html). The callback gets two arguments`(err, stats)` where `stats`is an [<fs.Stats>](https://nodejs.org/api/fs.html#class-fsstats) object.

In case of an error, the `err.code` will be one of [Common System Errors](https://nodejs.org/api/errors.html#common-system-errors).

[fs.stat()](#fsstatpath-options-callback) follows symbolic links. Use [fs.lstat()](#fslstatpath-options-callback) to look at the
links themselves.

Using `fs.stat()` to check for the existence of a file before calling `fs.open()`, `fs.readFile()`, or `fs.writeFile()` is not recommended.
Instead, user code should open/read/write the file directly and handle the
error raised if the file is not available.

To check if a file exists without manipulating it afterwards, [fs.access()](#fsaccesspath-mode-callback) is recommended.

For example, given the following directory structure:

```text
- txtDir
-- file.txt
- app.js
textcopy
```

The next program will check for the stats of the given paths:

```mjs
import { stat } from 'node:fs';

const pathsToCheck = ['./txtDir', './txtDir/file.txt'];

for (let i = 0; i < pathsToCheck.length; i++) {
  stat(pathsToCheck[i], (err, stats) => {
    console.log(stats.isDirectory());
    console.log(stats);
  });
}
mjscopy
```

The resulting output will resemble:

```console
true
Stats {
  dev: 16777220,
  mode: 16877,
  nlink: 3,
  uid: 501,
  gid: 20,
  rdev: 0,
  blksize: 4096,
  ino: 14214262,
  size: 96,
  blocks: 0,
  atimeMs: 1561174653071.963,
  mtimeMs: 1561174614583.3518,
  ctimeMs: 1561174626623.5366,
  birthtimeMs: 1561174126937.2893,
  atime: 2019-06-22T03:37:33.072Z,
  mtime: 2019-06-22T03:36:54.583Z,
  ctime: 2019-06-22T03:37:06.624Z,
  birthtime: 2019-06-22T03:28:46.937Z,
  atimeInstant: 2019-06-22T03:37:33.071963Z,
  mtimeInstant: 2019-06-22T03:36:54.5833518Z,
  ctimeInstant: 2019-06-22T03:37:06.6235366Z,
  birthtimeInstant: 2019-06-22T03:28:46.9372893Z
}
false
Stats {
  dev: 16777220,
  mode: 33188,
  nlink: 1,
  uid: 501,
  gid: 20,
  rdev: 0,
  blksize: 4096,
  ino: 14214074,
  size: 8,
  blocks: 8,
  atimeMs: 1561174616618.8555,
  mtimeMs: 1561174614584,
  ctimeMs: 1561174614583.8145,
  birthtimeMs: 1561174007710.7478,
  atime: 2019-06-22T03:36:56.619Z,
  mtime: 2019-06-22T03:36:54.584Z,
  ctime: 2019-06-22T03:36:54.584Z,
  birthtime: 2019-06-22T03:26:47.711Z,
  atimeInstant: 2019-06-22T03:36:56.6188555Z,
  mtimeInstant: 2019-06-22T03:36:54.584Z,
  ctimeInstant: 2019-06-22T03:36:54.5838145Z,
  birthtimeInstant: 2019-06-22T03:26:47.7107478Z
}
consolecopy
```

#### fs.statfs(path[, options], callback)#

Added in: v19.6.0, v18.15.0
- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `bigint`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) Whether the numeric values in the returned [<fs.StatFs>](https://nodejs.org/api/fs.html#class-fsstatfs) object should be`bigint`. **Default:**`false`.

- `callback`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function)
  - `err`[<Error>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Error)
  - `stats`[<fs.StatFs>](https://nodejs.org/api/fs.html#class-fsstatfs)

Asynchronous [statfs(2)](http://man7.org/linux/man-pages/man2/statfs.2.html). Returns information about the mounted file system which
contains`path`. The callback gets two arguments `(err, stats)` where `stats`is an [<fs.StatFs>](https://nodejs.org/api/fs.html#class-fsstatfs) object.

In case of an error, the `err.code` will be one of [Common System Errors](https://nodejs.org/api/errors.html#common-system-errors).

#### fs.symlink(target, path[, type], callback)#

Added in: v0.1.31
**History**

| Version | Changes |
| --- | --- |
| v18.0.0 | Passing an invalid callback to the `callback` argument now throws `ERR_INVALID_ARG_TYPE` instead of `ERR_INVALID_CALLBACK`. |
| v12.0.0 | If the `type` argument is left undefined, Node will autodetect `target` type and automatically select `dir` or `file`. |
| v7.6.0 | The `target` and `path` parameters can be WHATWG `URL` objects using `file:` protocol. Support is currently still _experimental_. |

- `target`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `type`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<null>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#null_type)**Default:**`null`
- `callback`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function)
  - `err`[<Error>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Error)

Creates the link called `path` pointing to `target`. No arguments other than a
possible exception are given to the completion callback.

See the POSIX [symlink(2)](http://man7.org/linux/man-pages/man2/symlink.2.html) documentation for more details.

The `type` argument is only available on Windows and ignored on other platforms.
It can be set to `'dir'`, `'file'`, or `'junction'`. If the `type` argument is `null`, Node.js will autodetect `target` type and use `'file'` or `'dir'`.
If the `target` does not exist, `'file'` will be used. Windows junction points
require the destination path to be absolute. When using `'junction'`, the `target` argument will automatically be normalized to absolute path. Junction
points on NTFS volumes can only point to directories.

Relative targets are relative to the link's parent directory.

```mjs
import { symlink } from 'node:fs';

symlink('./mew', './mewtwo', callback);
mjscopy
```

The above example creates a symbolic link `mewtwo` which points to `mew` in the
same directory:

```bash
$ tree .
.
├── mew
└── mewtwo -> ./mew
bashcopy
```

#### fs.truncate(path[, len], callback)#

Added in: v0.8.6
**History**

| Version | Changes |
| --- | --- |
| v18.0.0 | Passing an invalid callback to the `callback` argument now throws `ERR_INVALID_ARG_TYPE` instead of `ERR_INVALID_CALLBACK`. |
| v16.0.0 | The error returned may be an `AggregateError` if more than one error is returned. |
| v10.0.0 | The `callback` parameter is no longer optional. Not passing it will throw a `TypeError` at runtime. |
| v7.0.0 | The `callback` parameter is no longer optional. Not passing it will emit a deprecation warning with id DEP0013. |

- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `len`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)**Default:**`0`
- `callback`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function)
  - `err`[<Error>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Error) | [<AggregateError>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/AggregateError)

Truncates the file. No arguments other than a possible exception are
given to the completion callback. A file descriptor can also be passed as the
first argument. In this case, `fs.ftruncate()` is called.

```mjs
import { truncate } from 'node:fs';
// Assuming that 'path/file.txt' is a regular file.
truncate('path/file.txt', (err) => {
  if (err) throw err;
  console.log('path/file.txt was truncated');
});
const { truncate } = require('node:fs');
// Assuming that 'path/file.txt' is a regular file.
truncate('path/file.txt', (err) => {
  if (err) throw err;
  console.log('path/file.txt was truncated');
});
javascriptcopy
```

Passing a file descriptor is deprecated and may result in an error being thrown
in the future.

See the POSIX [truncate(2)](http://man7.org/linux/man-pages/man2/truncate.2.html) documentation for more details.

#### fs.unlink(path, callback)#

Added in: v0.0.2
**History**

| Version | Changes |
| --- | --- |
| v18.0.0 | Passing an invalid callback to the `callback` argument now throws `ERR_INVALID_ARG_TYPE` instead of `ERR_INVALID_CALLBACK`. |
| v10.0.0 | The `callback` parameter is no longer optional. Not passing it will throw a `TypeError` at runtime. |
| v7.6.0 | The `path` parameter can be a WHATWG `URL` object using `file:` protocol. |
| v7.0.0 | The `callback` parameter is no longer optional. Not passing it will emit a deprecation warning with id DEP0013. |

- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `callback`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function)
  - `err`[<Error>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Error)

Asynchronously removes a file or symbolic link. No arguments other than a
possible exception are given to the completion callback.

```mjs
import { unlink } from 'node:fs';
// Assuming that 'path/file.txt' is a regular file.
unlink('path/file.txt', (err) => {
  if (err) throw err;
  console.log('path/file.txt was deleted');
});
mjscopy
```

`fs.unlink()` will not work on a directory, empty or otherwise. To remove a
directory, use [fs.rmdir()](#fsrmdirpath-options-callback).

See the POSIX [unlink(2)](http://man7.org/linux/man-pages/man2/unlink.2.html) documentation for more details.

#### fs.unwatchFile(filename[, listener])#

Added in: v0.1.31
- `filename`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `listener`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function) Optional, a listener previously attached using`fs.watchFile()`

Stop watching for changes on `filename`. If `listener` is specified, only that
particular listener is removed. Otherwise, _all_ listeners are removed,
effectively stopping watching of `filename`.

Calling `fs.unwatchFile()` with a filename that is not being watched is a
no-op, not an error.

Using [fs.watch()](#fswatchfilename-options-listener) is more efficient than `fs.watchFile()` and `fs.unwatchFile()`. `fs.watch()` should be used instead of `fs.watchFile()` and `fs.unwatchFile()` when possible.

#### fs.utimes(path, atime, mtime, callback)#

Added in: v0.4.2
**History**

| Version | Changes |
| --- | --- |
| v18.0.0 | Passing an invalid callback to the `callback` argument now throws `ERR_INVALID_ARG_TYPE` instead of `ERR_INVALID_CALLBACK`. |
| v10.0.0 | The `callback` parameter is no longer optional. Not passing it will throw a `TypeError` at runtime. |
| v8.0.0 | `NaN`, `Infinity`, and `-Infinity` are no longer valid time specifiers. |
| v7.6.0 | The `path` parameter can be a WHATWG `URL` object using `file:` protocol. |
| v7.0.0 | The `callback` parameter is no longer optional. Not passing it will emit a deprecation warning with id DEP0013. |
| v4.1.0 | Numeric strings, `NaN`, and `Infinity` are now allowed time specifiers. |

- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `atime`[<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Date>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Date)
- `mtime`[<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Date>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Date)
- `callback`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function)
  - `err`[<Error>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Error)

Change the file system timestamps of the object referenced by `path`.

The `atime` and `mtime` arguments follow these rules:

- Values can be either numbers representing Unix epoch time in seconds, `Date`s, or a numeric string like `'123456789.0'`.
- If the value can not be converted to a number, or is `NaN`, `Infinity`, or `-Infinity`, an `Error` will be thrown.

#### fs.watch(filename[, options][, listener])#

Added in: v0.5.10
**History**

| Version | Changes |
| --- | --- |
| v26.1.0 | Added `throwIfNoEntry` option. |
| v19.1.0 | Added recursive support for Linux, AIX and IBMi. |
| v15.9.0, v14.17.0 | Added support for closing the watcher with an AbortSignal. |
| v7.6.0 | The `filename` parameter can be a WHATWG `URL` object using `file:` protocol. |
| v7.0.0 | The passed `options` object will never be modified. |

- `filename`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `options`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `persistent`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) Indicates whether the process should continue to run
as long as files are being watched.**Default:**`true`.
  - `recursive`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) Indicates whether all subdirectories should be
watched, or only the current directory. This applies when a directory is
specified, and only on supported platforms (See[caveats](#caveats)). **Default:**`false`.
  - `encoding`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) Specifies the character encoding to be used for the
filename passed to the listener.**Default:**`'utf8'`.
  - `signal`[<AbortSignal>](https://nodejs.org/api/globals.html#class-abortsignal) allows closing the watcher with an AbortSignal.
  - `throwIfNoEntry`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) Indicates whether an exception should be thrown when the
path does not exist.**Default:**`true`.
  - `ignore`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<RegExp>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/RegExp) | [<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function) | [<Array>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Array) Pattern(s) to ignore. Strings are
glob patterns (using[minimatch](https://github.com/isaacs/minimatch)), RegExp patterns are tested against
the filename, and functions receive the filename and return `true` to
ignore. **Default:**`undefined`.

- `listener`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function) | [<undefined>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#undefined_type)**Default:**`undefined`
  - `eventType`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type)
  - `filename`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<null>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#null_type)

- Returns: [<fs.FSWatcher>](https://nodejs.org/api/fs.html#fsfswatcher)

Watch for changes on `filename`, where `filename` is either a file or a
directory.

The second argument is optional. If `options` is provided as a string, it
specifies the `encoding`. Otherwise `options` should be passed as an object.

The listener callback gets two arguments `(eventType, filename)`. `eventType` is either `'rename'` or `'change'`, and `filename` is the name of the file
which triggered the event.

On most platforms, `'rename'` is emitted whenever a filename appears or
disappears in the directory.

The listener callback is attached to the `'change'`event fired by [<fs.FSWatcher>](https://nodejs.org/api/fs.html#fsfswatcher), but it is not the same thing as the`'change'` value of `eventType`.

If a `signal`is passed, aborting the corresponding AbortController will close
the returned [<fs.FSWatcher>](https://nodejs.org/api/fs.html#fsfswatcher).

#### Caveats#

The `fs.watch` API is not 100% consistent across platforms, and is
unavailable in some situations.

On Windows, no events will be emitted if the watched directory is moved or
renamed. An `EPERM` error is reported when the watched directory is deleted.

The `fs.watch` API does not provide any protection with respect
to malicious actions on the file system. For example, on Windows it is
implemented by monitoring changes in a directory versus specific files. This
allows substitution of a file and fs reporting changes on the new file
with the same filename.

#### Availability#

This feature depends on the underlying operating system providing a way
to be notified of file system changes.

- On Linux systems, this uses [inotify(7)](https://man7.org/linux/man-pages/man7/inotify.7.html).
- On BSD systems, this uses [kqueue(2)](https://www.freebsd.org/cgi/man.cgi?query=kqueue&sektion=2).
- On macOS, this uses [kqueue(2)](https://www.freebsd.org/cgi/man.cgi?query=kqueue&sektion=2) for files and [FSEvents](https://developer.apple.com/documentation/coreservices/file_system_events) for
directories.
- On SunOS systems (including Solaris and SmartOS), this uses [event ports](https://illumos.org/man/port_create).
- On Windows systems, this feature depends on [ReadDirectoryChangesW](https://docs.microsoft.com/en-us/windows/desktop/api/winbase/nf-winbase-readdirectorychangesw).
- On AIX systems, this feature depends on [AHAFS](https://developer.ibm.com/articles/au-aix_event_infrastructure/), which must be enabled.
- On IBM i systems, this feature is not supported.

If the underlying functionality is not available for some reason, then `fs.watch()` will not be able to function and may throw an exception.
For example, watching files or directories can be unreliable, and in some
cases impossible, on network file systems (NFS, SMB, etc) or host file systems
when using virtualization software such as Vagrant or Docker.

It is still possible to use `fs.watchFile()`, which uses stat polling, but
this method is slower and less reliable.

#### Inodes#

On Linux and macOS systems, `fs.watch()` resolves the path to an [inode](https://en.wikipedia.org/wiki/Inode) and
watches the inode. If the watched path is deleted and recreated, it is assigned
a new inode. The watch will emit an event for the delete but will continue
watching the _original_ inode. Events for the new inode will not be emitted.
This is expected behavior.

AIX files retain the same inode for the lifetime of a file. Saving and closing a
watched file on AIX will result in two notifications (one for adding new
content, and one for truncation).

#### Filename argument#

Providing `filename` argument in the callback is only supported on Linux,
macOS, Windows, and AIX. Even on supported platforms, `filename` is not always
guaranteed to be provided. Therefore, don't assume that `filename` argument is
always provided in the callback, and have some fallback logic if it is `null`.

```mjs
import { watch } from 'node:fs';
watch('somedir', (eventType, filename) => {
  console.log(`event type is: ${eventType}`);
  if (filename) {
    console.log(`filename provided: ${filename}`);
  } else {
    console.log('filename not provided');
  }
});
mjscopy
```

#### fs.watchFile(filename[, options], listener)#

Added in: v0.1.31
**History**

| Version | Changes |
| --- | --- |
| v10.5.0 | The `bigint` option is now supported. |
| v7.6.0 | The `filename` parameter can be a WHATWG `URL` object using `file:` protocol. |

- `filename`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `bigint`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type)**Default:**`false`
  - `persistent`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type)**Default:**`true`
  - `interval`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)**Default:**`5007`

- `listener`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function)
  - `current`[<fs.Stats>](https://nodejs.org/api/fs.html#class-fsstats)
  - `previous`[<fs.Stats>](https://nodejs.org/api/fs.html#class-fsstats)

- Returns: [<fs.StatWatcher>](https://nodejs.org/api/fs.html#class-fsstatwatcher)

Watch for changes on `filename`. The callback `listener` will be called each
time the file is accessed.

The `options` argument may be omitted. If provided, it should be an object. The `options` object may contain a boolean named `persistent` that indicates
whether the process should continue to run as long as files are being watched.
The `options` object may specify an `interval` property indicating how often the
target should be polled in milliseconds.

The `listener` gets two arguments the current stat object and the previous
stat object:

```mjs
import { watchFile } from 'node:fs';

watchFile('message.text', (curr, prev) => {
  console.log(`the current mtime is: ${curr.mtime}`);
  console.log(`the previous mtime was: ${prev.mtime}`);
});
mjscopy
```

These stat objects are instances of `fs.Stat`. If the `bigint` option is `true`,
the numeric values in these objects are specified as `BigInt`s.

To be notified when the file was modified, not just accessed, it is necessary
to compare `curr.mtimeMs` and `prev.mtimeMs`.

When an `fs.watchFile` operation results in an `ENOENT` error, it
will invoke the listener once, with all the fields zeroed (or, for dates, the
Unix Epoch). If the file is created later on, the listener will be called
again, with the latest stat objects. This is a change in functionality since
v0.10.

Using [fs.watch()](#fswatchfilename-options-listener) is more efficient than `fs.watchFile` and `fs.unwatchFile`. `fs.watch` should be used instead of `fs.watchFile` and `fs.unwatchFile` when possible.

When a file being watched by `fs.watchFile()` disappears and reappears,
then the contents of `previous` in the second callback event (the file's
reappearance) will be the same as the contents of `previous` in the first
callback event (its disappearance).

This happens when:

- the file is deleted, followed by a restore
- the file is renamed and then renamed a second time back to its original name

#### fs.write(fd, buffer, offset[, length[, position]], callback)#

Added in: v0.0.2
**History**

| Version | Changes |
| --- | --- |
| v18.0.0 | Passing an invalid callback to the `callback` argument now throws `ERR_INVALID_ARG_TYPE` instead of `ERR_INVALID_CALLBACK`. |
| v14.0.0 | The `buffer` parameter won't coerce unsupported input to strings anymore. |
| v10.10.0 | The `buffer` parameter can now be any `TypedArray` or a `DataView`. |
| v10.0.0 | The `callback` parameter is no longer optional. Not passing it will throw a `TypeError` at runtime. |
| v7.4.0 | The `buffer` parameter can now be a `Uint8Array`. |
| v7.2.0 | The `offset` and `length` parameters are optional now. |
| v7.0.0 | The `callback` parameter is no longer optional. Not passing it will emit a deprecation warning with id DEP0013. |

- `fd`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
- `buffer`[<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<TypedArray>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/TypedArray) | [<DataView>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/DataView)
- `offset`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)**Default:**`0`
- `length`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)**Default:**`buffer.byteLength - offset`
- `position`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<null>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#null_type)**Default:**`null`
- `callback`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function)
  - `err`[<Error>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Error)
  - `bytesWritten`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
  - `buffer`[<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<TypedArray>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/TypedArray) | [<DataView>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/DataView)

Write `buffer` to the file specified by `fd`.

`offset` determines the part of the buffer to be written, and `length` is
an integer specifying the number of bytes to write.

`position` refers to the offset from the beginning of the file where this data
should be written. If `typeof position !== 'number'`, the data will be written
at the current position. See [pwrite(2)](http://man7.org/linux/man-pages/man2/pwrite.2.html).

The callback will be given three arguments `(err, bytesWritten, buffer)` where `bytesWritten` specifies how many _bytes_ were written from `buffer`.

If this method is invoked as its [util.promisify()](https://nodejs.org/api/util.html#utilpromisifyoriginal)ed version, it returns
a promise for an `Object` with `bytesWritten` and `buffer` properties.

It is unsafe to use `fs.write()` multiple times on the same file without waiting
for the callback. For this scenario, [fs.createWriteStream()](#fscreatewritestreampath-options) is
recommended.

On Linux, positional writes don't work when the file is opened in append mode.
The kernel ignores the position argument and always appends the data to
the end of the file.

#### fs.write(fd, buffer[, options], callback)#

Added in: v18.3.0, v16.17.0
- `fd`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
- `buffer`[<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<TypedArray>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/TypedArray) | [<DataView>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/DataView)
- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `offset`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)**Default:**`0`
  - `length`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)**Default:**`buffer.byteLength - offset`
  - `position`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<null>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#null_type)**Default:**`null`

- `callback`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function)
  - `err`[<Error>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Error)
  - `bytesWritten`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
  - `buffer`[<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<TypedArray>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/TypedArray) | [<DataView>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/DataView)

Write `buffer` to the file specified by `fd`.

Similar to the above `fs.write` function, this version takes an
optional `options` object. If no `options` object is specified, it will
default with the above values.

#### fs.write(fd, string[, position[, encoding]], callback)#

Added in: v0.11.5
**History**

| Version | Changes |
| --- | --- |
| v19.0.0 | Passing to the `string` parameter an object with an own `toString` function is no longer supported. |
| v17.8.0 | Passing to the `string` parameter an object with an own `toString` function is deprecated. |
| v14.12.0 | The `string` parameter will stringify an object with an explicit `toString` function. |
| v14.0.0 | The `string` parameter won't coerce unsupported input to strings anymore. |
| v10.0.0 | The `callback` parameter is no longer optional. Not passing it will throw a `TypeError` at runtime. |
| v7.2.0 | The `position` parameter is optional now. |
| v7.0.0 | The `callback` parameter is no longer optional. Not passing it will emit a deprecation warning with id DEP0013. |

- `fd`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
- `string`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type)
- `position`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<null>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#null_type)**Default:**`null`
- `encoding`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type)**Default:**`'utf8'`
- `callback`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function)
  - `err`[<Error>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Error)
  - `written`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
  - `string`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type)

Write `string` to the file specified by `fd`. If `string` is not a string,
an exception is thrown.

`position` refers to the offset from the beginning of the file where this data
should be written. If `typeof position !== 'number'`the data will be written at
the current position. See [pwrite(2)](http://man7.org/linux/man-pages/man2/pwrite.2.html).

`encoding` is the expected string encoding.

The callback will receive the arguments `(err, written, string)` where `written` specifies how many _bytes_ the passed string required to be written. Bytes
written is not necessarily the same as string characters written. See [Buffer.byteLength](https://nodejs.org/api/buffer.html#static-method-bufferbytelengthstring-encoding).

It is unsafe to use `fs.write()` multiple times on the same file without waiting
for the callback. For this scenario, [fs.createWriteStream()](#fscreatewritestreampath-options) is
recommended.

On Linux, positional writes don't work when the file is opened in append mode.
The kernel ignores the position argument and always appends the data to
the end of the file.

On Windows, if the file descriptor is connected to the console (e.g. `fd == 1` or `stdout`) a string containing non-ASCII characters will not be rendered
properly by default, regardless of the encoding used.
It is possible to configure the console to render UTF-8 properly by changing the
active codepage with the `chcp 65001` command. See the [chcp](https://ss64.com/nt/chcp.html) docs for more
details.

#### fs.writeFile(file, data[, options], callback)#

Added in: v0.1.29
**History**

| Version | Changes |
| --- | --- |
| v21.0.0, v20.10.0 | The `flush` option is now supported. |
| v19.0.0 | Passing to the `string` parameter an object with an own `toString` function is no longer supported. |
| v18.0.0 | Passing an invalid callback to the `callback` argument now throws `ERR_INVALID_ARG_TYPE` instead of `ERR_INVALID_CALLBACK`. |
| v17.8.0 | Passing to the `string` parameter an object with an own `toString` function is deprecated. |
| v16.0.0 | The error returned may be an `AggregateError` if more than one error is returned. |
| v15.2.0, v14.17.0 | The options argument may include an AbortSignal to abort an ongoing writeFile request. |
| v14.12.0 | The `data` parameter will stringify an object with an explicit `toString` function. |
| v14.0.0 | The `data` parameter won't coerce unsupported input to strings anymore. |
| v10.10.0 | The `data` parameter can now be any `TypedArray` or a `DataView`. |
| v10.0.0 | The `callback` parameter is no longer optional. Not passing it will throw a `TypeError` at runtime. |
| v7.4.0 | The `data` parameter can now be a `Uint8Array`. |
| v7.0.0 | The `callback` parameter is no longer optional. Not passing it will emit a deprecation warning with id DEP0013. |
| v5.0.0 | The `file` parameter can be a file descriptor now. |

- `file`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api) | [<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) filename or file descriptor
- `data`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<TypedArray>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/TypedArray) | [<DataView>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/DataView)
- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object) | [<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type)
  - `encoding`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<null>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#null_type)**Default:**`'utf8'`
  - `mode`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)**Default:**`0o666`
  - `flag`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) See[support of file system flags](#file-system-flags). **Default:**`'w'`.
  - `flush`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) If all data is successfully written to the file, and`flush` is `true`, `fs.fsync()` is used to flush the data. **Default:**`false`.
  - `signal`[<AbortSignal>](https://nodejs.org/api/globals.html#class-abortsignal) allows aborting an in-progress writeFile

- `callback`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function)
  - `err`[<Error>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Error) | [<AggregateError>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/AggregateError)

When `file` is a filename, asynchronously writes data to the file, replacing the
file if it already exists. `data` can be a string or a buffer.

When `file` is a file descriptor, the behavior is similar to calling `fs.write()` directly (which is recommended). See the notes below on using
a file descriptor.

The `encoding` option is ignored if `data` is a buffer.

The `mode` option only affects the newly created file. See [fs.open()](#fsopenpath-flags-mode-callback) for more details.

```mjs
import { writeFile } from 'node:fs';
import { Buffer } from 'node:buffer';

const data = new Uint8Array(Buffer.from('Hello Node.js'));
writeFile('message.txt', data, (err) => {
  if (err) throw err;
  console.log('The file has been saved!');
});
mjscopy
```

If `options` is a string, then it specifies the encoding:

```mjs
import { writeFile } from 'node:fs';

writeFile('message.txt', 'Hello Node.js', 'utf8', callback);
mjscopy
```

It is unsafe to use `fs.writeFile()` multiple times on the same file without
waiting for the callback. For this scenario, [fs.createWriteStream()](#fscreatewritestreampath-options) is
recommended.

Similarly to `fs.readFile` - `fs.writeFile` is a convenience method that
performs multiple `write` calls internally to write the buffer passed to it.
For performance sensitive code consider using [fs.createWriteStream()](#fscreatewritestreampath-options).

It is possible to use an [<AbortSignal>](https://nodejs.org/api/globals.html#class-abortsignal) to cancel an`fs.writeFile()`.
Cancelation is "best effort", and some amount of data is likely still
to be written.

```mjs
import { writeFile } from 'node:fs';
import { Buffer } from 'node:buffer';

const controller = new AbortController();
const { signal } = controller;
const data = new Uint8Array(Buffer.from('Hello Node.js'));
writeFile('message.txt', data, { signal }, (err) => {
  // When a request is aborted - the callback is called with an AbortError
});
// When the request should be aborted
controller.abort();
mjscopy
```

Aborting an ongoing request does not abort individual operating
system requests but rather the internal buffering `fs.writeFile` performs.

#### Using fs.writeFile() with file descriptors#

When `file` is a file descriptor, the behavior is almost identical to directly
calling `fs.write()` like:

```mjs
import { write } from 'node:fs';
import { Buffer } from 'node:buffer';

write(fd, Buffer.from(data, options.encoding), callback);
mjscopy
```

The difference from directly calling `fs.write()` is that under some unusual
conditions, `fs.write()` might write only part of the buffer and need to be
retried to write the remaining data, whereas `fs.writeFile()` retries until
the data is entirely written (or an error occurs).

The implications of this are a common source of confusion. In
the file descriptor case, the file is not replaced! The data is not necessarily
written to the beginning of the file, and the file's original data may remain
before and/or after the newly written data.

For example, if `fs.writeFile()` is called twice in a row, first to write the
string `'Hello'`, then to write the string `', World'`, the file would contain `'Hello, World'`, and might contain some of the file's original data (depending
on the size of the original file, and the position of the file descriptor). If
a file name had been used instead of a descriptor, the file would be guaranteed
to contain only `', World'`.

#### fs.writev(fd, buffers[, position], callback)#

Added in: v12.9.0
**History**

| Version | Changes |
| --- | --- |
| v18.0.0 | Passing an invalid callback to the `callback` argument now throws `ERR_INVALID_ARG_TYPE` instead of `ERR_INVALID_CALLBACK`. |

- `fd`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
- `buffers`{ArrayBufferView[]}
- `position`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<null>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#null_type)**Default:**`null`
- `callback`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function)
  - `err`[<Error>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Error)
  - `bytesWritten`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
  - `buffers`{ArrayBufferView[]}

Write an array of `ArrayBufferView`s to the file specified by `fd` using `writev()`.

`position` is the offset from the beginning of the file where this data
should be written. If `typeof position !== 'number'`, the data will be written
at the current position.

The callback will be given three arguments: `err`, `bytesWritten`, and `buffers`. `bytesWritten` is how many bytes were written from `buffers`.

If this method is [util.promisify()](https://nodejs.org/api/util.html#utilpromisifyoriginal)ed, it returns a promise for an `Object` with `bytesWritten` and `buffers` properties.

It is unsafe to use `fs.writev()` multiple times on the same file without
waiting for the callback. For this scenario, use [fs.createWriteStream()](#fscreatewritestreampath-options).

On Linux, positional writes don't work when the file is opened in append mode.
The kernel ignores the position argument and always appends the data to
the end of the file.

### Synchronous API#

The synchronous APIs perform all operations synchronously, blocking the
event loop until the operation completes or fails.

#### fs.accessSync(path[, mode])#

Added in: v0.11.15
**History**

| Version | Changes |
| --- | --- |
| v7.6.0 | The `path` parameter can be a WHATWG `URL` object using `file:` protocol. |

- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `mode`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)**Default:**`fs.constants.F_OK`

Synchronously tests a user's permissions for the file or directory specified
by `path`. The `mode` argument is an optional integer that specifies the
accessibility checks to be performed. `mode` should be either the value `fs.constants.F_OK` or a mask consisting of the bitwise OR of any of `fs.constants.R_OK`, `fs.constants.W_OK`, and `fs.constants.X_OK` (e.g. `fs.constants.W_OK | fs.constants.R_OK`). Check [File access constants](#file-access-constants) for
possible values of `mode`.

If any of the accessibility checks fail, an `Error` will be thrown. Otherwise,
the method will return `undefined`.

```mjs
import { accessSync, constants } from 'node:fs';

try {
  accessSync('etc/passwd', constants.R_OK | constants.W_OK);
  console.log('can read/write');
} catch (err) {
  console.error('no access!');
}
mjscopy
```

#### fs.appendFileSync(path, data[, options])#

Added in: v0.6.7
**History**

| Version | Changes |
| --- | --- |
| v21.1.0, v20.10.0 | The `flush` option is now supported. |
| v7.0.0 | The passed `options` object will never be modified. |
| v5.0.0 | The `file` parameter can be a file descriptor now. |

- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api) | [<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) filename or file descriptor
- `data`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer)
- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object) | [<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type)
  - `encoding`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<null>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#null_type)**Default:**`'utf8'`
  - `mode`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)**Default:**`0o666`
  - `flag`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) See[support of file system flags](#file-system-flags). **Default:**`'a'`.
  - `flush`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) If`true`, the underlying file descriptor is flushed
prior to closing it. **Default:**`false`.

Synchronously append data to a file, creating the file if it does not yet
exist. `data`can be a string or a [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer).

The `mode` option only affects the newly created file. See [fs.open()](#fsopenpath-flags-mode-callback) for more details.

```mjs
import { appendFileSync } from 'node:fs';

try {
  appendFileSync('message.txt', 'data to append');
  console.log('The "data to append" was appended to file!');
} catch (err) {
  /* Handle the error */
}
mjscopy
```

If `options` is a string, then it specifies the encoding:

```mjs
import { appendFileSync } from 'node:fs';

appendFileSync('message.txt', 'data to append', 'utf8');
mjscopy
```

The `path` may be specified as a numeric file descriptor that has been opened
for appending (using `fs.open()` or `fs.openSync()`). The file descriptor will
not be closed automatically.

```mjs
import { openSync, closeSync, appendFileSync } from 'node:fs';

let fd;

try {
  fd = openSync('message.txt', 'a');
  appendFileSync(fd, 'data to append', 'utf8');
} catch (err) {
  /* Handle the error */
} finally {
  if (fd !== undefined)
    closeSync(fd);
}
mjscopy
```

#### fs.chmodSync(path, mode)#

Added in: v0.6.7
**History**

| Version | Changes |
| --- | --- |
| v7.6.0 | The `path` parameter can be a WHATWG `URL` object using `file:` protocol. |

- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `mode`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)

For detailed information, see the documentation of the asynchronous version of
this API: [fs.chmod()](#fschmodpath-mode-callback).

See the POSIX [chmod(2)](http://man7.org/linux/man-pages/man2/chmod.2.html) documentation for more detail.

#### fs.chownSync(path, uid, gid)#

Added in: v0.1.97
**History**

| Version | Changes |
| --- | --- |
| v7.6.0 | The `path` parameter can be a WHATWG `URL` object using `file:` protocol. |

- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `uid`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
- `gid`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)

Synchronously changes owner and group of a file. Returns `undefined`.
This is the synchronous version of [fs.chown()](#fschownpath-uid-gid-callback).

See the POSIX [chown(2)](http://man7.org/linux/man-pages/man2/chown.2.html) documentation for more detail.

#### fs.closeSync(fd)#

Added in: v0.1.21
- `fd`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)

Closes the file descriptor. Returns `undefined`.

Calling `fs.closeSync()` on any file descriptor (`fd`) that is currently in use
through any other `fs` operation may lead to undefined behavior.

See the POSIX [close(2)](http://man7.org/linux/man-pages/man2/close.2.html) documentation for more detail.

#### fs.copyFileSync(src, dest[, mode])#

Added in: v8.5.0
**History**

| Version | Changes |
| --- | --- |
| v14.0.0 | Changed `flags` argument to `mode` and imposed stricter type validation. |

- `src`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api) source filename to copy
- `dest`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api) destination filename of the copy operation
- `mode`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) modifiers for copy operation.**Default:**`0`.

Synchronously copies `src` to `dest`. By default, `dest` is overwritten if it
already exists. Returns `undefined`. Node.js makes no guarantees about the
atomicity of the copy operation. If an error occurs after the destination file
has been opened for writing, Node.js will attempt to remove the destination.

`mode` is an optional integer that specifies the behavior
of the copy operation. It is possible to create a mask consisting of the bitwise
OR of two or more values (e.g. `fs.constants.COPYFILE_EXCL | fs.constants.COPYFILE_FICLONE`).

- `fs.constants.COPYFILE_EXCL`: The copy operation will fail if `dest` already
exists.
- `fs.constants.COPYFILE_FICLONE`: The copy operation will attempt to create a
copy-on-write reflink. If the platform does not support copy-on-write, then a
fallback copy mechanism is used.
- `fs.constants.COPYFILE_FICLONE_FORCE`: The copy operation will attempt to
create a copy-on-write reflink. If the platform does not support
copy-on-write, then the operation will fail.

```mjs
import { copyFileSync, constants } from 'node:fs';

// destination.txt will be created or overwritten by default.
copyFileSync('source.txt', 'destination.txt');
console.log('source.txt was copied to destination.txt');

// By using COPYFILE_EXCL, the operation will fail if destination.txt exists.
copyFileSync('source.txt', 'destination.txt', constants.COPYFILE_EXCL);
mjscopy
```

#### fs.cpSync(src, dest[, options])#

Added in: v16.7.0
**History**

| Version | Changes |
| --- | --- |
| v22.3.0 | This API is no longer experimental. |
| v20.1.0, v18.17.0 | Accept an additional `mode` option to specify the copy behavior as the `mode` argument of `fs.copyFile()`. |
| v17.6.0, v16.15.0 | Accepts an additional `verbatimSymlinks` option to specify whether to perform path resolution for symlinks. |

- `src`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api) source path to copy.
- `dest`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api) destination path to copy to.
- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `dereference`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) dereference symlinks.**Default:**`false`.
  - `errorOnExist`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) when`force` is `false`, and the destination
exists, throw an error. **Default:**`false`.
  - `filter`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function) Function to filter copied files/directories. Return`true` to copy the item, `false` to ignore it. When ignoring a directory,
all of its contents will be skipped as well. **Default:**`undefined`
    - `src`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) source path to copy.
    - `dest`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) destination path to copy to.
    - Returns: [<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) Any non-`Promise` value that is coercible
to `boolean`.

  - `force`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) overwrite existing file or directory. The copy
operation will ignore errors if you set this to false and the destination
exists. Use the`errorOnExist` option to change this behavior. **Default:**`true`.
  - `mode`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) modifiers for copy operation.**Default:**`0`.
See `mode` flag of [fs.copyFileSync()](#fscopyfilesyncsrc-dest-mode).
  - `preserveTimestamps`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) When`true` timestamps from `src` will
be preserved. **Default:**`false`.
  - `recursive`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) copy directories recursively**Default:**`false`
  - `verbatimSymlinks`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) When`true`, path resolution for symlinks will
be skipped. **Default:**`false`

Synchronously copies the entire directory structure from `src` to `dest`,
including subdirectories and files.

When copying a directory to another directory, globs are not supported and
behavior is similar to `cp dir1/ dir2/`.

#### fs.existsSync(path)#

Added in: v0.1.21
**History**

| Version | Changes |
| --- | --- |
| v7.6.0 | The `path` parameter can be a WHATWG `URL` object using `file:` protocol. |

- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- Returns: [<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type)

Returns `true` if the path exists, `false` otherwise.

For detailed information, see the documentation of the asynchronous version of
this API: [fs.exists()](#fsexistspath-callback).

`fs.exists()` is deprecated, but `fs.existsSync()` is not. The `callback` parameter to `fs.exists()` accepts parameters that are inconsistent with other
Node.js callbacks. `fs.existsSync()` does not use a callback.

```mjs
import { existsSync } from 'node:fs';

if (existsSync('/etc/passwd'))
  console.log('The path exists.');
mjscopy
```

#### fs.fchmodSync(fd, mode)#

Added in: v0.4.7
- `fd`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
- `mode`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)

Sets the permissions on the file. Returns `undefined`.

See the POSIX [fchmod(2)](http://man7.org/linux/man-pages/man2/fchmod.2.html) documentation for more detail.

#### fs.fchownSync(fd, uid, gid)#

Added in: v0.4.7
- `fd`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
- `uid`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) The file's new owner's user id.
- `gid`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) The file's new group's group id.

Sets the owner of the file. Returns `undefined`.

See the POSIX [fchown(2)](http://man7.org/linux/man-pages/man2/fchown.2.html) documentation for more detail.

#### fs.fdatasyncSync(fd)#

Added in: v0.1.96
- `fd`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)

Forces all currently queued I/O operations associated with the file to the
operating system's synchronized I/O completion state. Refer to the POSIX [fdatasync(2)](http://man7.org/linux/man-pages/man2/fdatasync.2.html) documentation for details. Returns`undefined`.

#### fs.fstatSync(fd[, options])#

Added in: v0.1.95
**History**

| Version | Changes |
| --- | --- |
| v10.5.0 | Accepts an additional `options` object to specify whether the numeric values returned should be bigint. |

- `fd`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `bigint`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) Whether the numeric values in the returned [<fs.Stats>](https://nodejs.org/api/fs.html#class-fsstats) object should be`bigint`. **Default:**`false`.

- Returns: [<fs.Stats>](https://nodejs.org/api/fs.html#class-fsstats)

Retrieves the [<fs.Stats>](https://nodejs.org/api/fs.html#class-fsstats) for the file descriptor.

See the POSIX [fstat(2)](http://man7.org/linux/man-pages/man2/fstat.2.html) documentation for more detail.

#### fs.fsyncSync(fd)#

Added in: v0.1.96
- `fd`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)

Request that all data for the open file descriptor is flushed to the storage
device. The specific implementation is operating system and device specific.
Refer to the POSIX [fsync(2)](http://man7.org/linux/man-pages/man2/fsync.2.html) documentation for more detail. Returns`undefined`.

#### fs.ftruncateSync(fd[, len])#

Added in: v0.8.6
- `fd`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
- `len`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)**Default:**`0`

Truncates the file descriptor. Returns `undefined`.

For detailed information, see the documentation of the asynchronous version of
this API: [fs.ftruncate()](#fsftruncatefd-len-callback).

#### fs.futimesSync(fd, atime, mtime)#

Added in: v0.4.2
**History**

| Version | Changes |
| --- | --- |
| v4.1.0 | Numeric strings, `NaN`, and `Infinity` are now allowed time specifiers. |

- `fd`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
- `atime`[<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Date>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Date)
- `mtime`[<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Date>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Date)

Synchronous version of [fs.futimes()](#fsfutimesfd-atime-mtime-callback). Returns `undefined`.

#### fs.globSync(pattern[, options])#

Added in: v22.0.0
**History**

| Version | Changes |
| --- | --- |
| v26.1.0 | Add support for the `followSymlinks` option. |
| v24.1.0, v22.17.0 | Add support for `URL` instances for `cwd` option. |
| v24.0.0, v22.17.0 | Marking the API stable. |
| v23.7.0, v22.14.0 | Add support for `exclude` option to accept glob patterns. |
| v22.2.0 | Add support for `withFileTypes` as an option. |

- `pattern`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<string[]>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type)
- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `cwd`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api) current working directory.**Default:**`process.cwd()`
  - `exclude`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function) | [<string[]>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) Function to filter out files/directories or a
list of glob patterns to be excluded. If a function is provided, return`true` to exclude the item, `false` to include it. **Default:**`undefined`.
  - `followSymlinks`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) When`true`, symbolic links to directories are
followed while expanding `**` patterns. **Default:**`false`.
  - `withFileTypes`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type)`true` if the glob should return paths as Dirents, `false` otherwise. **Default:**`false`.

- Returns: [<string[]>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) paths of files that match the pattern.

When `followSymlinks` is enabled, detected symbolic link cycles are not
traversed recursively.

```mjs
import { globSync } from 'node:fs';

console.log(globSync('**/*.js'));
const { globSync } = require('node:fs');

console.log(globSync('**/*.js'));
javascriptcopy
```

#### fs.lchmodSync(path, mode)#

Deprecated in: v0.4.7
Stability: 0 - Deprecated

- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `mode`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)

Changes the permissions on a symbolic link. Returns `undefined`.

This method is only implemented on macOS.

See the POSIX [lchmod(2)](http://man7.org/linux/man-pages/man2/lchmod.2.html) documentation for more detail.

#### fs.lchownSync(path, uid, gid)#

**History**

| Version | Changes |
| --- | --- |
| v10.6.0 | This API is no longer deprecated. |
| v0.4.7 | Documentation-only deprecation. |

- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `uid`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) The file's new owner's user id.
- `gid`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) The file's new group's group id.

Set the owner for the path. Returns `undefined`.

See the POSIX [lchown(2)](http://man7.org/linux/man-pages/man2/lchown.2.html) documentation for more details.

#### fs.lutimesSync(path, atime, mtime)#

Added in: v14.5.0, v12.19.0
- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `atime`[<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Date>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Date)
- `mtime`[<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Date>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Date)

Change the file system timestamps of the symbolic link referenced by `path`.
Returns `undefined`, or throws an exception when parameters are incorrect or
the operation fails. This is the synchronous version of [fs.lutimes()](#fslutimespath-atime-mtime-callback).

#### fs.linkSync(existingPath, newPath)#

Added in: v0.1.31
**History**

| Version | Changes |
| --- | --- |
| v7.6.0 | The `existingPath` and `newPath` parameters can be WHATWG `URL` objects using `file:` protocol. Support is currently still _experimental_. |

- `existingPath`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `newPath`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)

Creates a new link from the `existingPath` to the `newPath`. See the POSIX [link(2)](http://man7.org/linux/man-pages/man2/link.2.html) documentation for more detail. Returns`undefined`.

#### fs.lstatSync(path[, options])#

Added in: v0.1.30
**History**

| Version | Changes |
| --- | --- |
| v15.3.0, v14.17.0 | Accepts a `throwIfNoEntry` option to specify whether an exception should be thrown if the entry does not exist. |
| v10.5.0 | Accepts an additional `options` object to specify whether the numeric values returned should be bigint. |
| v7.6.0 | The `path` parameter can be a WHATWG `URL` object using `file:` protocol. |

- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `bigint`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) Whether the numeric values in the returned [<fs.Stats>](https://nodejs.org/api/fs.html#class-fsstats) object should be`bigint`. **Default:**`false`.
  - `throwIfNoEntry`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) Whether an exception will be thrown
if no file system entry exists, rather than returning`undefined`. **Default:**`true`.

- Returns: [<fs.Stats>](https://nodejs.org/api/fs.html#class-fsstats)

Retrieves the [<fs.Stats>](https://nodejs.org/api/fs.html#class-fsstats) for the symbolic link referred to by`path`.

See the POSIX [lstat(2)](http://man7.org/linux/man-pages/man2/lstat.2.html) documentation for more details.

#### fs.mkdirSync(path[, options])#

Added in: v0.1.21
**History**

| Version | Changes |
| --- | --- |
| v13.11.0, v12.17.0 | In `recursive` mode, the first created path is returned now. |
| v10.12.0 | The second argument can now be an `options` object with `recursive` and `mode` properties. |
| v7.6.0 | The `path` parameter can be a WHATWG `URL` object using `file:` protocol. |

- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object) | [<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
  - `recursive`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type)**Default:**`false`
  - `mode`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) Not supported on Windows.**Default:**`0o777`.

- Returns: [<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<undefined>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#undefined_type)

Synchronously creates a directory. Returns `undefined`, or if `recursive` is `true`, the first directory path created.
This is the synchronous version of [fs.mkdir()](#fsmkdirpath-options-callback).

See the POSIX [mkdir(2)](http://man7.org/linux/man-pages/man2/mkdir.2.html) documentation for more details.

#### fs.mkdtempSync(prefix[, options])#

Added in: v5.10.0
**History**

| Version | Changes |
| --- | --- |
| v20.6.0, v18.19.0 | The `prefix` parameter now accepts buffers and URL. |
| v16.5.0, v14.18.0 | The `prefix` parameter now accepts an empty string. |

- `prefix`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `options`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `encoding`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type)**Default:**`'utf8'`

- Returns: [<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type)

Returns the created directory path.

For detailed information, see the documentation of the asynchronous version of
this API: [fs.mkdtemp()](#fsmkdtempprefix-options-callback).

The optional `options` argument can be a string specifying an encoding, or an
object with an `encoding` property specifying the character encoding to use.

#### fs.mkdtempDisposableSync(prefix[, options])#

Added in: v24.4.0
- `prefix`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `options`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `encoding`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type)**Default:**`'utf8'`

- Returns: [<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object) A disposable object:
  - `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) The path of the created directory.
  - `remove`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function) A function which removes the created directory.
  - `[Symbol.dispose]`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function) The same as`remove`.

Returns a disposable object whose `path` property holds the created directory
path. When the object is disposed, the directory and its contents will be
removed if it still exists. If the directory cannot be deleted, disposal will
throw an error. The object has a `remove()` method which will perform the same
task.

For detailed information, see the documentation of [fs.mkdtemp()](#fsmkdtempprefix-options-callback).

There is no callback-based version of this API because it is designed for use
with the `using` syntax.

The optional `options` argument can be a string specifying an encoding, or an
object with an `encoding` property specifying the character encoding to use.

#### fs.opendirSync(path[, options])#

Added in: v12.12.0
**History**

| Version | Changes |
| --- | --- |
| v20.1.0, v18.17.0 | Added `recursive` option. |
| v13.1.0, v12.16.0 | The `bufferSize` option was introduced. |

- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `encoding`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<null>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#null_type)**Default:**`'utf8'`
  - `bufferSize`[<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) Number of directory entries that are buffered
internally when reading from the directory. Higher values lead to better
performance but higher memory usage.**Default:**`32`
  - `recursive`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type)**Default:**`false`

- Returns: [<fs.Dir>](https://nodejs.org/api/fs.html#class-fsdir)

Synchronously open a directory. See [opendir(3)](http://man7.org/linux/man-pages/man3/opendir.3.html).

Creates an [<fs.Dir>](https://nodejs.org/api/fs.html#class-fsdir), which contains all further functions for reading from
and cleaning up the directory.

The `encoding` option sets the encoding for the `path` while opening the
directory and subsequent read operations.

#### fs.openSync(path[, flags[, mode]])#

Added in: v0.1.21
**History**

| Version | Changes |
| --- | --- |
| v11.1.0 | The `flags` argument is now optional and defaults to `'r'`. |
| v9.9.0 | The `as` and `as+` flags are supported now. |
| v7.6.0 | The `path` parameter can be a WHATWG `URL` object using `file:` protocol. |

- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `flags`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)**Default:**`'r'`.
See [support of file system flags](#file-system-flags).
- `mode`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)**Default:**`0o666`
- Returns: [<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)

Returns an integer representing the file descriptor.

For detailed information, see the documentation of the asynchronous version of
this API: [fs.open()](#fsopenpath-flags-mode-callback).

#### fs.readdirSync(path[, options])#

Added in: v0.1.21
**History**

| Version | Changes |
| --- | --- |
| v20.1.0, v18.17.0 | Added `recursive` option. |
| v10.10.0 | New option `withFileTypes` was added. |
| v7.6.0 | The `path` parameter can be a WHATWG `URL` object using `file:` protocol. |

- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `options`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `encoding`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type)**Default:**`'utf8'`
  - `withFileTypes`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type)**Default:**`false`
  - `recursive`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) If`true`, reads the contents of a directory
recursively. In recursive mode, it will list all files, sub files, and
directories. **Default:**`false`.

- Returns: [<string[]>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer[]>](buffer.html#class-buffer) | [<fs.Dirent[]>](fs.html#class-fsdirent)

Reads the contents of the directory.

See the POSIX [readdir(3)](http://man7.org/linux/man-pages/man3/readdir.3.html) documentation for more details.

The optional `options` argument can be a string specifying an encoding, or an
object with an `encoding` property specifying the character encoding to use for
the filenames returned. If the `encoding` is set to `'buffer'`,
the filenames returned will be passed as [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) objects.

If `options.withFileTypes` is set to `true`, the result will contain [<fs.Dirent>](https://nodejs.org/api/fs.html#class-fsdirent) objects.

#### fs.readFileSync(path[, options])#

Added in: v0.1.8
**History**

| Version | Changes |
| --- | --- |
| v7.6.0 | The `path` parameter can be a WHATWG `URL` object using `file:` protocol. |
| v5.0.0 | The `path` parameter can be a file descriptor now. |

- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api) | [<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) filename or file descriptor
- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object) | [<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type)
  - `encoding`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<null>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#null_type)**Default:**`null`
  - `flag`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) See[support of file system flags](#file-system-flags). **Default:**`'r'`.

- Returns: [<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer)

Returns the contents of the `path`.

For detailed information, see the documentation of the asynchronous version of
this API: [fs.readFile()](#fsreadfilepath-options-callback).

If the `encoding` option is specified then this function returns a
string. Otherwise it returns a buffer.

Similar to [fs.readFile()](#fsreadfilepath-options-callback), when the path is a directory, the behavior of `fs.readFileSync()` is platform-specific.

```mjs
import { readFileSync } from 'node:fs';

// macOS, Linux, and Windows
readFileSync('<directory>');
// => [Error: EISDIR: illegal operation on a directory, read <directory>]

//  FreeBSD
readFileSync('<directory>'); // => <data>
mjscopy
```

#### fs.readlinkSync(path[, options])#

Added in: v0.1.31
**History**

| Version | Changes |
| --- | --- |
| v7.6.0 | The `path` parameter can be a WHATWG `URL` object using `file:` protocol. |

- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `options`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `encoding`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type)**Default:**`'utf8'`

- Returns: [<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer)

Returns the symbolic link's string value.

See the POSIX [readlink(2)](http://man7.org/linux/man-pages/man2/readlink.2.html) documentation for more details.

The optional `options` argument can be a string specifying an encoding, or an
object with an `encoding` property specifying the character encoding to use for
the link path returned. If the `encoding` is set to `'buffer'`,
the link path returned will be passed as a [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) object.

#### fs.readSync(fd, buffer, offset, length[, position])#

Added in: v0.1.21
**History**

| Version | Changes |
| --- | --- |
| v10.10.0 | The `buffer` parameter can now be any `TypedArray` or a `DataView`. |
| v6.0.0 | The `length` parameter can now be `0`. |

- `fd`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
- `buffer`[<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<TypedArray>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/TypedArray) | [<DataView>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/DataView)
- `offset`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
- `length`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
- `position`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<bigint>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#bigint_type) | [<null>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#null_type)**Default:**`null`
- Returns: [<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)

Returns the number of `bytesRead`.

For detailed information, see the documentation of the asynchronous version of
this API: [fs.read()](#fsreadfd-buffer-offset-length-position-callback).

#### fs.readSync(fd, buffer[, options])#

Added in: v13.13.0, v12.17.0
**History**

| Version | Changes |
| --- | --- |
| v13.13.0, v12.17.0 | Options object can be passed in to make offset, length, and position optional. |

- `fd`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
- `buffer`[<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<TypedArray>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/TypedArray) | [<DataView>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/DataView)
- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `offset`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)**Default:**`0`
  - `length`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)**Default:**`buffer.byteLength - offset`
  - `position`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<bigint>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#bigint_type) | [<null>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#null_type)**Default:**`null`

- Returns: [<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)

Returns the number of `bytesRead`.

Similar to the above `fs.readSync` function, this version takes an optional `options` object.
If no `options` object is specified, it will default with the above values.

For detailed information, see the documentation of the asynchronous version of
this API: [fs.read()](#fsreadfd-buffer-offset-length-position-callback).

#### fs.readvSync(fd, buffers[, position])#

Added in: v13.13.0, v12.17.0
- `fd`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
- `buffers`{ArrayBufferView[]}
- `position`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<null>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#null_type)**Default:**`null`
- Returns: [<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) The number of bytes read.

For detailed information, see the documentation of the asynchronous version of
this API: [fs.readv()](#fsreadvfd-buffers-position-callback).

#### fs.realpathSync(path[, options])#

Added in: v0.1.31
**History**

| Version | Changes |
| --- | --- |
| v8.0.0 | Pipe/Socket resolve support was added. |
| v7.6.0 | The `path` parameter can be a WHATWG `URL` object using `file:` protocol. |
| v6.4.0 | Calling `realpathSync` now works again for various edge cases on Windows. |
| v6.0.0 | The `cache` parameter was removed. |

- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `options`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `encoding`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type)**Default:**`'utf8'`

- Returns: [<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer)

Returns the resolved pathname.

For detailed information, see the documentation of the asynchronous version of
this API: [fs.realpath()](#fsrealpathpath-options-callback).

#### fs.realpathSync.native(path[, options])#

Added in: v9.2.0
- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `options`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `encoding`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type)**Default:**`'utf8'`

- Returns: [<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer)

Synchronous [realpath(3)](http://man7.org/linux/man-pages/man3/realpath.3.html).

Only paths that can be converted to UTF8 strings are supported.

The optional `options` argument can be a string specifying an encoding, or an
object with an `encoding` property specifying the character encoding to use for
the path returned. If the `encoding` is set to `'buffer'`,
the path returned will be passed as a [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) object.

On Linux, when Node.js is linked against musl libc, the procfs file system must
be mounted on `/proc` in order for this function to work. Glibc does not have
this restriction.

#### fs.renameSync(oldPath, newPath)#

Added in: v0.1.21
**History**

| Version | Changes |
| --- | --- |
| v7.6.0 | The `oldPath` and `newPath` parameters can be WHATWG `URL` objects using `file:` protocol. Support is currently still _experimental_. |

- `oldPath`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `newPath`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)

Renames the file from `oldPath` to `newPath`. Returns `undefined`.

See the POSIX [rename(2)](http://man7.org/linux/man-pages/man2/rename.2.html) documentation for more details.

#### fs.rmdirSync(path[, options])#

Added in: v0.1.21
**History**

| Version | Changes |
| --- | --- |
| v25.0.0 | Remove `recursive` option. |
| v16.0.0 | Using `fs.rmdirSync(path, { recursive: true })` on a `path` that is a file is no longer permitted and results in an `ENOENT` error on Windows and an `ENOTDIR` error on POSIX. |
| v16.0.0 | Using `fs.rmdirSync(path, { recursive: true })` on a `path` that does not exist is no longer permitted and results in a `ENOENT` error. |
| v16.0.0 | The `recursive` option is deprecated, using it triggers a deprecation warning. |
| v14.14.0 | The `recursive` option is deprecated, use `fs.rmSync` instead. |
| v13.3.0, v12.16.0 | The `maxBusyTries` option is renamed to `maxRetries`, and its default is 0. The `emfileWait` option has been removed, and `EMFILE` errors use the same retry logic as other errors. The `retryDelay` option is now supported. `ENFILE` errors are now retried. |
| v12.10.0 | The `recursive`, `maxBusyTries`, and `emfileWait` options are now supported. |
| v7.6.0 | The `path` parameters can be a WHATWG `URL` object using `file:` protocol. |

- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object) There are currently no options exposed. There used to
be options for`recursive`, `maxBusyTries`, and `emfileWait` but they were
deprecated and removed. The `options` argument is still accepted for
backwards compatibility but it is not used.

Synchronous [rmdir(2)](http://man7.org/linux/man-pages/man2/rmdir.2.html). Returns`undefined`.

Using `fs.rmdirSync()` on a file (not a directory) results in an `ENOENT` error
on Windows and an `ENOTDIR` error on POSIX.

To get a behavior similar to the `rm -rf` Unix command, use [fs.rmSync()](#fsrmsyncpath-options) with options `{ recursive: true, force: true }`.

#### fs.rmSync(path[, options])#

Added in: v14.14.0
**History**

| Version | Changes |
| --- | --- |
| v17.3.0, v16.14.0 | The `path` parameter can be a WHATWG `URL` object using `file:` protocol. |

- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `force`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) When`true`, exceptions will be ignored if `path` does
not exist. **Default:**`false`.
  - `maxRetries`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) If an`EBUSY`, `EMFILE`, `ENFILE`, `ENOTEMPTY`, or `EPERM` error is encountered, Node.js will retry the operation with a linear
backoff wait of `retryDelay` milliseconds longer on each try. This option
represents the number of retries. This option is ignored if the `recursive` option is not `true`. **Default:**`0`.
  - `recursive`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) If`true`, perform a recursive directory removal. In
recursive mode operations are retried on failure. **Default:**`false`.
  - `retryDelay`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) The amount of time in milliseconds to wait between
retries. This option is ignored if the`recursive` option is not `true`. **Default:**`100`.

Synchronously removes files and directories (modeled on the standard POSIX `rm` utility). Returns `undefined`.

#### fs.statSync(path[, options])#

Added in: v0.1.21
**History**

| Version | Changes |
| --- | --- |
| v15.3.0, v14.17.0 | Accepts a `throwIfNoEntry` option to specify whether an exception should be thrown if the entry does not exist. |
| v10.5.0 | Accepts an additional `options` object to specify whether the numeric values returned should be bigint. |
| v7.6.0 | The `path` parameter can be a WHATWG `URL` object using `file:` protocol. |

- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `bigint`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) Whether the numeric values in the returned [<fs.Stats>](https://nodejs.org/api/fs.html#class-fsstats) object should be`bigint`. **Default:**`false`.
  - `throwIfNoEntry`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) Whether an exception will be thrown
if no file system entry exists, rather than returning`undefined`. **Default:**`true`.

- Returns: [<fs.Stats>](https://nodejs.org/api/fs.html#class-fsstats)

Retrieves the [<fs.Stats>](https://nodejs.org/api/fs.html#class-fsstats) for the path.

#### fs.statfsSync(path[, options])#

Added in: v19.6.0, v18.15.0
- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `bigint`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) Whether the numeric values in the returned [<fs.StatFs>](https://nodejs.org/api/fs.html#class-fsstatfs) object should be`bigint`. **Default:**`false`.

- Returns: [<fs.StatFs>](https://nodejs.org/api/fs.html#class-fsstatfs)

Synchronous [statfs(2)](http://man7.org/linux/man-pages/man2/statfs.2.html). Returns information about the mounted file system which
contains`path`.

In case of an error, the `err.code` will be one of [Common System Errors](https://nodejs.org/api/errors.html#common-system-errors).

#### fs.symlinkSync(target, path[, type])#

Added in: v0.1.31
**History**

| Version | Changes |
| --- | --- |
| v12.0.0 | If the `type` argument is left undefined, Node will autodetect `target` type and automatically select `dir` or `file`. |
| v7.6.0 | The `target` and `path` parameters can be WHATWG `URL` objects using `file:` protocol. Support is currently still _experimental_. |

- `target`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `type`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<null>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#null_type)**Default:**`null`
- Returns: `undefined`.

For detailed information, see the documentation of the asynchronous version of
this API: [fs.symlink()](#fssymlinktarget-path-type-callback).

#### fs.truncateSync(path[, len])#

Added in: v0.8.6
- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `len`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)**Default:**`0`

Truncates the file. Returns `undefined`. A file descriptor can also be
passed as the first argument. In this case, `fs.ftruncateSync()` is called.

Passing a file descriptor is deprecated and may result in an error being thrown
in the future.

#### fs.unlinkSync(path)#

Added in: v0.1.21
**History**

| Version | Changes |
| --- | --- |
| v7.6.0 | The `path` parameter can be a WHATWG `URL` object using `file:` protocol. |

- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)

Synchronous [unlink(2)](http://man7.org/linux/man-pages/man2/unlink.2.html). Returns`undefined`.

#### fs.utimesSync(path, atime, mtime)#

Added in: v0.4.2
**History**

| Version | Changes |
| --- | --- |
| v8.0.0 | `NaN`, `Infinity`, and `-Infinity` are no longer valid time specifiers. |
| v7.6.0 | The `path` parameter can be a WHATWG `URL` object using `file:` protocol. |
| v4.1.0 | Numeric strings, `NaN`, and `Infinity` are now allowed time specifiers. |

- `path`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)
- `atime`[<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Date>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Date)
- `mtime`[<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Date>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Date)
- Returns: `undefined`.

For detailed information, see the documentation of the asynchronous version of
this API: [fs.utimes()](#fsutimespath-atime-mtime-callback).

#### fs.writeFileSync(file, data[, options])#

Added in: v0.1.29
**History**

| Version | Changes |
| --- | --- |
| v21.0.0, v20.10.0 | The `flush` option is now supported. |
| v19.0.0 | Passing to the `data` parameter an object with an own `toString` function is no longer supported. |
| v17.8.0 | Passing to the `data` parameter an object with an own `toString` function is deprecated. |
| v14.12.0 | The `data` parameter will stringify an object with an explicit `toString` function. |
| v14.0.0 | The `data` parameter won't coerce unsupported input to strings anymore. |
| v10.10.0 | The `data` parameter can now be any `TypedArray` or a `DataView`. |
| v7.4.0 | The `data` parameter can now be a `Uint8Array`. |
| v5.0.0 | The `file` parameter can be a file descriptor now. |

- `file`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api) | [<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) filename or file descriptor
- `data`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<TypedArray>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/TypedArray) | [<DataView>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/DataView)
- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object) | [<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type)
  - `encoding`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<null>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#null_type)**Default:**`'utf8'`
  - `mode`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)**Default:**`0o666`
  - `flag`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) See[support of file system flags](#file-system-flags). **Default:**`'w'`.
  - `flush`[<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) If all data is successfully written to the file, and`flush` is `true`, `fs.fsyncSync()` is used to flush the data.

- Returns: `undefined`.

The `mode` option only affects the newly created file. See [fs.open()](#fsopenpath-flags-mode-callback) for more details.

For detailed information, see the documentation of the asynchronous version of
this API: [fs.writeFile()](#fswritefilefile-data-options-callback).

#### fs.writeSync(fd, buffer, offset[, length[, position]])#

Added in: v0.1.21
**History**

| Version | Changes |
| --- | --- |
| v14.0.0 | The `buffer` parameter won't coerce unsupported input to strings anymore. |
| v10.10.0 | The `buffer` parameter can now be any `TypedArray` or a `DataView`. |
| v7.4.0 | The `buffer` parameter can now be a `Uint8Array`. |
| v7.2.0 | The `offset` and `length` parameters are optional now. |

- `fd`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
- `buffer`[<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<TypedArray>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/TypedArray) | [<DataView>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/DataView)
- `offset`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)**Default:**`0`
- `length`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)**Default:**`buffer.byteLength - offset`
- `position`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<null>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#null_type)**Default:**`null`
- Returns: [<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) The number of bytes written.

For detailed information, see the documentation of the asynchronous version of
this API: [fs.write(fd, buffer...)](#fswritefd-buffer-offset-length-position-callback).

#### fs.writeSync(fd, buffer[, options])#

Added in: v18.3.0, v16.17.0
- `fd`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
- `buffer`[<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<TypedArray>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/TypedArray) | [<DataView>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/DataView)
- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `offset`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)**Default:**`0`
  - `length`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)**Default:**`buffer.byteLength - offset`
  - `position`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<null>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#null_type)**Default:**`null`

- Returns: [<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) The number of bytes written.

For detailed information, see the documentation of the asynchronous version of
this API: [fs.write(fd, buffer...)](#fswritefd-buffer-offset-length-position-callback).

#### fs.writeSync(fd, string[, position[, encoding]])#

Added in: v0.11.5
**History**

| Version | Changes |
| --- | --- |
| v14.0.0 | The `string` parameter won't coerce unsupported input to strings anymore. |
| v7.2.0 | The `position` parameter is optional now. |

- `fd`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
- `string`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type)
- `position`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<null>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#null_type)**Default:**`null`
- `encoding`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type)**Default:**`'utf8'`
- Returns: [<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) The number of bytes written.

For detailed information, see the documentation of the asynchronous version of
this API: [fs.write(fd, string...)](#fswritefd-string-position-encoding-callback).

#### fs.writevSync(fd, buffers[, position])#

Added in: v12.9.0
- `fd`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
- `buffers`{ArrayBufferView[]}
- `position`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<null>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#null_type)**Default:**`null`
- Returns: [<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) The number of bytes written.

For detailed information, see the documentation of the asynchronous version of
this API: [fs.writev()](#fswritevfd-buffers-position-callback).

### Common Objects#

The common objects are shared by all of the file system API variants
(promise, callback, and synchronous).

#### Class: fs.Dir#

Added in: v12.12.0
A class representing a directory stream.

Created by [fs.opendir()](#fsopendirpath-options-callback), [fs.opendirSync()](#fsopendirsyncpath-options), or [fsPromises.opendir()](#fspromisesopendirpath-options).

```mjs
import { opendir } from 'node:fs/promises';

try {
  const dir = await opendir('./');
  for await (const dirent of dir)
    console.log(dirent.name);
} catch (err) {
  console.error(err);
}
mjscopy
```

When using the async iterator, the [<fs.Dir>](https://nodejs.org/api/fs.html#class-fsdir) object will be automatically
closed after the iterator exits.

#### dir.close()#

Added in: v12.12.0
- Returns: [<Promise>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Promise)

Asynchronously close the directory's underlying resource handle.
Subsequent reads will result in errors.

A promise is returned that will be fulfilled after the resource has been
closed.

#### dir.close(callback)#

Added in: v12.12.0
**History**

| Version | Changes |
| --- | --- |
| v18.0.0 | Passing an invalid callback to the `callback` argument now throws `ERR_INVALID_ARG_TYPE` instead of `ERR_INVALID_CALLBACK`. |

- `callback`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function)
  - `err`[<Error>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Error)

Asynchronously close the directory's underlying resource handle.
Subsequent reads will result in errors.

The `callback` will be called after the resource handle has been closed.

#### dir.closeSync()#

Added in: v12.12.0
Synchronously close the directory's underlying resource handle.
Subsequent reads will result in errors.

#### dir.path#

Added in: v12.12.0
- Type: [<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type)

The read-only path of this directory as was provided to [fs.opendir()](#fsopendirpath-options-callback), [fs.opendirSync()](#fsopendirsyncpath-options), or [fsPromises.opendir()](#fspromisesopendirpath-options).

#### dir.read()#

Added in: v12.12.0
- Returns: [<Promise>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Promise) Fulfills with a [<fs.Dirent>](https://nodejs.org/api/fs.html#class-fsdirent) | [<null>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#null_type)

Asynchronously read the next directory entry via [readdir(3)](http://man7.org/linux/man-pages/man3/readdir.3.html) as an[<fs.Dirent>](https://nodejs.org/api/fs.html#class-fsdirent).

A promise is returned that will be fulfilled with an [<fs.Dirent>](https://nodejs.org/api/fs.html#class-fsdirent), or`null` if there are no more directory entries to read.

Directory entries returned by this function are in no particular order as
provided by the operating system's underlying directory mechanisms.
Entries added or removed while iterating over the directory might not be
included in the iteration results.

#### dir.read(callback)#

Added in: v12.12.0
- `callback`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function)
  - `err`[<Error>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Error)
  - `dirent`[<fs.Dirent>](https://nodejs.org/api/fs.html#class-fsdirent) | [<null>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#null_type)

Asynchronously read the next directory entry via [readdir(3)](http://man7.org/linux/man-pages/man3/readdir.3.html) as an[<fs.Dirent>](https://nodejs.org/api/fs.html#class-fsdirent).

After the read is completed, the `callback`will be called with an [<fs.Dirent>](https://nodejs.org/api/fs.html#class-fsdirent), or`null` if there are no more directory entries to read.

Directory entries returned by this function are in no particular order as
provided by the operating system's underlying directory mechanisms.
Entries added or removed while iterating over the directory might not be
included in the iteration results.

#### dir.readSync()#

Added in: v12.12.0
- Returns: [<fs.Dirent>](https://nodejs.org/api/fs.html#class-fsdirent) | [<null>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#null_type)

Synchronously read the next directory entry as an [<fs.Dirent>](https://nodejs.org/api/fs.html#class-fsdirent). See the
POSIX [readdir(3)](http://man7.org/linux/man-pages/man3/readdir.3.html) documentation for more detail.

If there are no more directory entries to read, `null` will be returned.

Directory entries returned by this function are in no particular order as
provided by the operating system's underlying directory mechanisms.
Entries added or removed while iterating over the directory might not be
included in the iteration results.

#### dir[Symbol.asyncIterator]()#

Added in: v12.12.0
- Returns: [<AsyncIterator>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/AsyncIterator) An AsyncIterator of [<fs.Dirent>](https://nodejs.org/api/fs.html#class-fsdirent)

Asynchronously iterates over the directory until all entries have
been read. Refer to the POSIX [readdir(3)](http://man7.org/linux/man-pages/man3/readdir.3.html) documentation for more detail.

Entries returned by the async iterator are always an [<fs.Dirent>](https://nodejs.org/api/fs.html#class-fsdirent).
The`null` case from `dir.read()` is handled internally.

See [<fs.Dir>](https://nodejs.org/api/fs.html#class-fsdir) for an example.

Directory entries returned by this iterator are in no particular order as
provided by the operating system's underlying directory mechanisms.
Entries added or removed while iterating over the directory might not be
included in the iteration results.

#### dir[Symbol.asyncDispose]()#

Added in: v24.1.0, v22.1.0
**History**

| Version | Changes |
| --- | --- |
| v24.2.0 | No longer experimental. |

Calls `dir.close()` if the directory handle is open, and returns a promise that
fulfills when disposal is complete.

#### dir[Symbol.dispose]()#

Added in: v24.1.0, v22.1.0
**History**

| Version | Changes |
| --- | --- |
| v24.2.0 | No longer experimental. |

Calls `dir.closeSync()` if the directory handle is open, and returns `undefined`.

#### Class: fs.Dirent#

Added in: v10.10.0
A representation of a directory entry, which can be a file or a subdirectory
within the directory, as returned by reading from an [<fs.Dir>](https://nodejs.org/api/fs.html#class-fsdir). The
directory entry is a combination of the file name and file type pairs.

Additionally, when [fs.readdir()](#fsreaddirpath-options-callback) or [fs.readdirSync()](#fsreaddirsyncpath-options) is called with
the `withFileTypes` option set to `true`, the resulting array is filled with [<fs.Dirent>](https://nodejs.org/api/fs.html#class-fsdirent) objects, rather than strings or [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer)s.

#### dirent.isBlockDevice()#

Added in: v10.10.0
- Returns: [<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type)

Returns `true`if the [<fs.Dirent>](https://nodejs.org/api/fs.html#class-fsdirent) object describes a block device.

#### dirent.isCharacterDevice()#

Added in: v10.10.0
- Returns: [<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type)

Returns `true`if the [<fs.Dirent>](https://nodejs.org/api/fs.html#class-fsdirent) object describes a character device.

#### dirent.isDirectory()#

Added in: v10.10.0
- Returns: [<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type)

Returns `true`if the [<fs.Dirent>](https://nodejs.org/api/fs.html#class-fsdirent) object describes a file system
directory.

#### dirent.isFIFO()#

Added in: v10.10.0
- Returns: [<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type)

Returns `true`if the [<fs.Dirent>](https://nodejs.org/api/fs.html#class-fsdirent) object describes a first-in-first-out
(FIFO) pipe.

#### dirent.isFile()#

Added in: v10.10.0
- Returns: [<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type)

Returns `true`if the [<fs.Dirent>](https://nodejs.org/api/fs.html#class-fsdirent) object describes a regular file.

#### dirent.isSocket()#

Added in: v10.10.0
- Returns: [<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type)

Returns `true`if the [<fs.Dirent>](https://nodejs.org/api/fs.html#class-fsdirent) object describes a socket.

#### dirent.isSymbolicLink()#

Added in: v10.10.0
- Returns: [<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type)

Returns `true`if the [<fs.Dirent>](https://nodejs.org/api/fs.html#class-fsdirent) object describes a symbolic link.

#### dirent.name#

Added in: v10.10.0
- Type: [<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer)

The file name that this [<fs.Dirent>](https://nodejs.org/api/fs.html#class-fsdirent) object refers to. The type of this
value is determined by the`options.encoding` passed to [fs.readdir()](#fsreaddirpath-options-callback) or [fs.readdirSync()](#fsreaddirsyncpath-options).

#### dirent.parentPath#

Added in: v21.4.0, v20.12.0, v18.20.0
**History**

| Version | Changes |
| --- | --- |
| v24.0.0, v22.17.0 | Marking the API stable. |

- Type: [<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type)

The path to the parent directory of the file this [<fs.Dirent>](https://nodejs.org/api/fs.html#class-fsdirent) object refers to.

#### Class: fs.FSWatcher#

Added in: v0.5.8
- Extends [<EventEmitter>](https://nodejs.org/api/events.html#class-eventemitter)

A successful call to [fs.watch()](#fswatchfilename-options-listener)method will return a new [<fs.FSWatcher>](https://nodejs.org/api/fs.html#fsfswatcher) object.

All [<fs.FSWatcher>](https://nodejs.org/api/fs.html#fsfswatcher) objects emit a`'change'` event whenever a specific watched
file is modified.

#### Event: 'change'#

Added in: v0.5.8
- `eventType`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) The type of change event that has occurred
- `filename`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) The filename that changed (if relevant/available)

Emitted when something changes in a watched directory or file.
See more details in [fs.watch()](#fswatchfilename-options-listener).

The `filename` argument may not be provided depending on operating system
support. If `filename`is provided, it will be provided as a [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) if`fs.watch()` is called with its `encoding` option set to `'buffer'`, otherwise `filename` will be a UTF-8 string.

```mjs
import { watch } from 'node:fs';
// Example when handled through fs.watch() listener
watch('./tmp', { encoding: 'buffer' }, (eventType, filename) => {
  if (filename) {
    console.log(filename);
    // Prints: <Buffer ...>
  }
});
mjscopy
```

#### Event: 'close'#

Added in: v10.0.0
Emitted when the watcher stops watching for changes. The closed [<fs.FSWatcher>](https://nodejs.org/api/fs.html#fsfswatcher) object is no longer usable in the event handler.

#### Event: 'error'#

Added in: v0.5.8
- `error`[<Error>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Error)

Emitted when an error occurs while watching the file. The errored [<fs.FSWatcher>](https://nodejs.org/api/fs.html#fsfswatcher) object is no longer usable in the event handler.

#### watcher.close()#

Added in: v0.5.8
Stop watching for changes on the given [<fs.FSWatcher>](https://nodejs.org/api/fs.html#fsfswatcher). Once stopped, the [<fs.FSWatcher>](https://nodejs.org/api/fs.html#fsfswatcher) object is no longer usable.

#### watcher.ref()#

Added in: v14.3.0, v12.20.0
- Returns: [<fs.FSWatcher>](https://nodejs.org/api/fs.html#fsfswatcher)

When called, requests that the Node.js event loop _not_exit so long as the [<fs.FSWatcher>](https://nodejs.org/api/fs.html#fsfswatcher) is active. Calling`watcher.ref()` multiple times will have
no effect.

By default, all [<fs.FSWatcher>](https://nodejs.org/api/fs.html#fsfswatcher) objects are "ref'ed", making it normally
unnecessary to call`watcher.ref()` unless `watcher.unref()` had been
called previously.

#### watcher.unref()#

Added in: v14.3.0, v12.20.0
- Returns: [<fs.FSWatcher>](https://nodejs.org/api/fs.html#fsfswatcher)

When called, the active [<fs.FSWatcher>](https://nodejs.org/api/fs.html#fsfswatcher) object will not require the Node.js
event loop to remain active. If there is no other activity keeping the
event loop running, the process may exit before the [<fs.FSWatcher>](https://nodejs.org/api/fs.html#fsfswatcher) object's
callback is invoked. Calling`watcher.unref()` multiple times will have
no effect.

#### Class: fs.StatWatcher#

Added in: v14.3.0, v12.20.0
- Extends [<EventEmitter>](https://nodejs.org/api/events.html#class-eventemitter)

A successful call to `fs.watchFile()`method will return a new [<fs.StatWatcher>](https://nodejs.org/api/fs.html#class-fsstatwatcher) object.

#### watcher.ref()#

Added in: v14.3.0, v12.20.0
- Returns: [<fs.StatWatcher>](https://nodejs.org/api/fs.html#class-fsstatwatcher)

When called, requests that the Node.js event loop _not_exit so long as the [<fs.StatWatcher>](https://nodejs.org/api/fs.html#class-fsstatwatcher) is active. Calling`watcher.ref()` multiple times will have
no effect.

By default, all [<fs.StatWatcher>](https://nodejs.org/api/fs.html#class-fsstatwatcher) objects are "ref'ed", making it normally
unnecessary to call`watcher.ref()` unless `watcher.unref()` had been
called previously.

#### watcher.unref()#

Added in: v14.3.0, v12.20.0
- Returns: [<fs.StatWatcher>](https://nodejs.org/api/fs.html#class-fsstatwatcher)

When called, the active [<fs.StatWatcher>](https://nodejs.org/api/fs.html#class-fsstatwatcher) object will not require the Node.js
event loop to remain active. If there is no other activity keeping the
event loop running, the process may exit before the [<fs.StatWatcher>](https://nodejs.org/api/fs.html#class-fsstatwatcher) object's
callback is invoked. Calling`watcher.unref()` multiple times will have
no effect.

#### Class: fs.ReadStream#

Added in: v0.1.93
- Extends: [<stream.Readable>](https://nodejs.org/api/stream.html#class-streamreadable)

Instances of [<fs.ReadStream>](https://nodejs.org/api/fs.html#class-fsreadstream) cannot be constructed directly. They are created and
returned using the[fs.createReadStream()](#fscreatereadstreampath-options) function.

#### Event: 'close'#

Added in: v0.1.93
Emitted when the [<fs.ReadStream>](https://nodejs.org/api/fs.html#class-fsreadstream)'s underlying file descriptor has been closed.

#### Event: 'open'#

Added in: v0.1.93
- `fd`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) Integer file descriptor used by the [<fs.ReadStream>](https://nodejs.org/api/fs.html#class-fsreadstream).

Emitted when the [<fs.ReadStream>](https://nodejs.org/api/fs.html#class-fsreadstream)'s file descriptor has been opened.

#### Event: 'ready'#

Added in: v9.11.0
Emitted when the [<fs.ReadStream>](https://nodejs.org/api/fs.html#class-fsreadstream) is ready to be used.

Fires immediately after `'open'`.

#### readStream.bytesRead#

Added in: v6.4.0
- Type: [<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)

The number of bytes that have been read so far.

#### readStream.path#

Added in: v0.1.93
- Type: [<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer)

The path to the file the stream is reading from as specified in the first
argument to `fs.createReadStream()`. If `path` is passed as a string, then `readStream.path` will be a string. If `path`is passed as a [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer), then`readStream.path`will be a [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer). If`fd` is specified, then `readStream.path` will be `undefined`.

#### readStream.pending#

Added in: v11.2.0, v10.16.0
- Type: [<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type)

This property is `true` if the underlying file has not been opened yet,
i.e. before the `'ready'` event is emitted.

#### Class: fs.Stats#

Added in: v0.1.21
**History**

| Version | Changes |
| --- | --- |
| v26.2.0 | Added `Temporal.Instant` support. |
| v22.0.0, v20.13.0 | Public constructor is deprecated. |
| v8.1.0 | Added times as numbers. |

A [<fs.Stats>](https://nodejs.org/api/fs.html#class-fsstats) object provides information about a file.

Objects returned from [fs.stat()](#fsstatpath-options-callback), [fs.lstat()](#fslstatpath-options-callback), [fs.fstat()](#fsfstatfd-options-callback), and
their synchronous counterparts are of this type.
If `bigint` in the `options` passed to those methods is true, the numeric values
will be `bigint` instead of `number`, and the object will contain additional
nanosecond-precision properties suffixed with `Ns`. `Stat` objects are not to be created directly using the `new` keyword.

```console
Stats {
  dev: 2114,
  ino: 48064969,
  mode: 33188,
  nlink: 1,
  uid: 85,
  gid: 100,
  rdev: 0,
  size: 527,
  blksize: 4096,
  blocks: 8,
  atimeMs: 1318289051000.1,
  mtimeMs: 1318289051000.1,
  ctimeMs: 1318289051000.1,
  birthtimeMs: 1318289051000.1,

  // Instances of Date
  atime: Mon, 10 Oct 2011 23:24:11 GMT,
  mtime: Mon, 10 Oct 2011 23:24:11 GMT,
  ctime: Mon, 10 Oct 2011 23:24:11 GMT,
  birthtime: Mon, 10 Oct 2011 23:24:11 GMT,

  // Instances of Temporal.Instant
  atimeInstant: 2011-10-10T23:24:11.0001Z,
  mtimeInstant: 2011-10-10T23:24:11.0001Z,
  ctimeInstant: 2011-10-10T23:24:11.0001Z,
  birthtimeInstant: 2011-10-10T23:24:11.0001Z
}
consolecopy
```

`bigint` version:

```console
BigIntStats {
  dev: 2114n,
  ino: 48064969n,
  mode: 33188n,
  nlink: 1n,
  uid: 85n,
  gid: 100n,
  rdev: 0n,
  size: 527n,
  blksize: 4096n,
  blocks: 8n,
  atimeMs: 1318289051000n,
  mtimeMs: 1318289051000n,
  ctimeMs: 1318289051000n,
  birthtimeMs: 1318289051000n,
  atimeNs: 1318289051000000000n,
  mtimeNs: 1318289051000000000n,
  ctimeNs: 1318289051000000000n,
  birthtimeNs: 1318289051000000000n,

  // Instances of Date
  atime: Mon, 10 Oct 2011 23:24:11 GMT,
  mtime: Mon, 10 Oct 2011 23:24:11 GMT,
  ctime: Mon, 10 Oct 2011 23:24:11 GMT,
  birthtime: Mon, 10 Oct 2011 23:24:11 GMT,

  // Instances of Temporal.Instant
  atimeInstant: 2011-10-10T23:24:11Z,
  mtimeInstant: 2011-10-10T23:24:11Z,
  ctimeInstant: 2011-10-10T23:24:11Z,
  birthtimeInstant: 2011-10-10T23:24:11Z
}
consolecopy
```

#### stats.isBlockDevice()#

Added in: v0.1.10
- Returns: [<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type)

Returns `true`if the [<fs.Stats>](https://nodejs.org/api/fs.html#class-fsstats) object describes a block device.

#### stats.isCharacterDevice()#

Added in: v0.1.10
- Returns: [<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type)

Returns `true`if the [<fs.Stats>](https://nodejs.org/api/fs.html#class-fsstats) object describes a character device.

#### stats.isDirectory()#

Added in: v0.1.10
- Returns: [<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type)

Returns `true`if the [<fs.Stats>](https://nodejs.org/api/fs.html#class-fsstats) object describes a file system directory.

If the [<fs.Stats>](https://nodejs.org/api/fs.html#class-fsstats) object was obtained from calling[fs.lstat()](#fslstatpath-options-callback) on a
symbolic link which resolves to a directory, this method will return `false`.
This is because [fs.lstat()](#fslstatpath-options-callback) returns information
about a symbolic link itself and not the path it resolves to.

#### stats.isFIFO()#

Added in: v0.1.10
- Returns: [<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type)

Returns `true`if the [<fs.Stats>](https://nodejs.org/api/fs.html#class-fsstats) object describes a first-in-first-out (FIFO)
pipe.

#### stats.isFile()#

Added in: v0.1.10
- Returns: [<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type)

Returns `true`if the [<fs.Stats>](https://nodejs.org/api/fs.html#class-fsstats) object describes a regular file.

#### stats.isSocket()#

Added in: v0.1.10
- Returns: [<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type)

Returns `true`if the [<fs.Stats>](https://nodejs.org/api/fs.html#class-fsstats) object describes a socket.

#### stats.isSymbolicLink()#

Added in: v0.1.10
- Returns: [<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type)

Returns `true`if the [<fs.Stats>](https://nodejs.org/api/fs.html#class-fsstats) object describes a symbolic link.

This method is only valid when using [fs.lstat()](#fslstatpath-options-callback).

#### stats.dev#

- Type: [<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<bigint>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#bigint_type)

The numeric identifier of the device containing the file.

#### stats.ino#

- Type: [<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<bigint>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#bigint_type)

The file system specific "Inode" number for the file.

#### stats.mode#

- Type: [<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<bigint>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#bigint_type)

A bit-field describing the file type and mode.

#### stats.nlink#

- Type: [<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<bigint>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#bigint_type)

The number of hard-links that exist for the file.

#### stats.uid#

- Type: [<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<bigint>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#bigint_type)

The numeric user identifier of the user that owns the file (POSIX).

#### stats.gid#

- Type: [<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<bigint>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#bigint_type)

The numeric group identifier of the group that owns the file (POSIX).

#### stats.rdev#

- Type: [<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<bigint>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#bigint_type)

A numeric device identifier if the file represents a device.

#### stats.size#

- Type: [<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<bigint>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#bigint_type)

The size of the file in bytes.

If the underlying file system does not support getting the size of the file,
this will be `0`.

#### stats.blksize#

- Type: [<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<bigint>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#bigint_type)

The file system block size for i/o operations.

#### stats.blocks#

- Type: [<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<bigint>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#bigint_type)

The number of blocks allocated for this file.

#### stats.atimeMs#

Added in: v8.1.0
- Type: [<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<bigint>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#bigint_type)

The timestamp indicating the last time this file was accessed expressed in
milliseconds since the POSIX Epoch.

#### stats.mtimeMs#

Added in: v8.1.0
- Type: [<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<bigint>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#bigint_type)

The timestamp indicating the last time this file was modified expressed in
milliseconds since the POSIX Epoch.

#### stats.ctimeMs#

Added in: v8.1.0
- Type: [<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<bigint>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#bigint_type)

The timestamp indicating the last time the file status was changed expressed
in milliseconds since the POSIX Epoch.

#### stats.birthtimeMs#

Added in: v8.1.0
- Type: [<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<bigint>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#bigint_type)

The timestamp indicating the creation time of this file expressed in
milliseconds since the POSIX Epoch.

#### stats.atimeNs#

Added in: v12.10.0
- Type: [<bigint>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#bigint_type)

Only present when `bigint: true` is passed into the method that generates
the object.
The timestamp indicating the last time this file was accessed expressed in
nanoseconds since the POSIX Epoch.

#### stats.mtimeNs#

Added in: v12.10.0
- Type: [<bigint>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#bigint_type)

Only present when `bigint: true` is passed into the method that generates
the object.
The timestamp indicating the last time this file was modified expressed in
nanoseconds since the POSIX Epoch.

#### stats.ctimeNs#

Added in: v12.10.0
- Type: [<bigint>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#bigint_type)

Only present when `bigint: true` is passed into the method that generates
the object.
The timestamp indicating the last time the file status was changed expressed
in nanoseconds since the POSIX Epoch.

#### stats.birthtimeNs#

Added in: v12.10.0
- Type: [<bigint>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#bigint_type)

Only present when `bigint: true` is passed into the method that generates
the object.
The timestamp indicating the creation time of this file expressed in
nanoseconds since the POSIX Epoch.

#### stats.atime#

Added in: v0.11.13
- Type: [<Date>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Date)

The timestamp indicating the last time this file was accessed.

#### stats.mtime#

Added in: v0.11.13
- Type: [<Date>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Date)

The timestamp indicating the last time this file was modified.

#### stats.ctime#

Added in: v0.11.13
- Type: [<Date>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Date)

The timestamp indicating the last time the file status was changed.

#### stats.birthtime#

Added in: v0.11.13
- Type: [<Date>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Date)

The timestamp indicating the creation time of this file.

#### Stat time values#

The `atimeMs`, `mtimeMs`, `ctimeMs`, `birthtimeMs` properties are
numeric values that hold the corresponding times in milliseconds. Their
precision is platform specific. When `bigint: true` is passed into the
method that generates the object, the properties will be [bigints](https://tc39.github.io/proposal-bigint),
otherwise they will be [numbers](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Guide/Data_structures#number_type).

The `atimeNs`, `mtimeNs`, `ctimeNs`, `birthtimeNs` properties are [bigints](https://tc39.github.io/proposal-bigint) that hold the corresponding times in nanoseconds. They are
only present when `bigint: true` is passed into the method that generates
the object. Their precision is platform specific.

`atime`, `mtime`, `ctime`, and `birthtime` are [Date](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Date) object alternate representations of the various times. The `Date` and number values are not connected. Assigning a new number value, or
mutating the `Date` value, will not be reflected in the corresponding alternate
representation.

The times in the stat object have the following semantics:

- `atime`"Access Time": Time when file data last accessed. Changed
by the [mknod(2)](http://man7.org/linux/man-pages/man2/mknod.2.html), [utimes(2)](http://man7.org/linux/man-pages/man2/utimes.2.html), and [read(2)](http://man7.org/linux/man-pages/man2/read.2.html) system calls.
- `mtime`"Modified Time": Time when file data last modified.
Changed by the [mknod(2)](http://man7.org/linux/man-pages/man2/mknod.2.html), [utimes(2)](http://man7.org/linux/man-pages/man2/utimes.2.html), and [write(2)](http://man7.org/linux/man-pages/man2/write.2.html) system calls.
- `ctime`"Change Time": Time when file status was last changed
(inode data modification). Changed by the [chmod(2)](http://man7.org/linux/man-pages/man2/chmod.2.html), [chown(2)](http://man7.org/linux/man-pages/man2/chown.2.html), [link(2)](http://man7.org/linux/man-pages/man2/link.2.html), [mknod(2)](http://man7.org/linux/man-pages/man2/mknod.2.html), [rename(2)](http://man7.org/linux/man-pages/man2/rename.2.html), [unlink(2)](http://man7.org/linux/man-pages/man2/unlink.2.html), [utimes(2)](http://man7.org/linux/man-pages/man2/utimes.2.html), [read(2)](http://man7.org/linux/man-pages/man2/read.2.html), and [write(2)](http://man7.org/linux/man-pages/man2/write.2.html) system calls.
- `birthtime` "Birth Time": Time of file creation. Set once when the
file is created. On file systems where birthtime is not available,
this field may instead hold either the `ctime` or `1970-01-01T00:00Z` (ie, Unix epoch timestamp `0`). This value may be greater
than `atime` or `mtime` in this case. On Darwin and other FreeBSD variants,
also set if the `atime` is explicitly set to an earlier value than the current `birthtime`using the [utimes(2)](http://man7.org/linux/man-pages/man2/utimes.2.html) system call.

Prior to Node.js 0.12, the `ctime` held the `birthtime` on Windows systems. As
of 0.12, `ctime` is not "creation time", and on Unix systems, it never was.

#### Class: fs.StatFs#

Added in: v19.6.0, v18.15.0
Provides information about a mounted file system.

Objects returned from [fs.statfs()](#fsstatfspath-options-callback) and its synchronous counterpart are of
this type. If `bigint` in the `options` passed to those methods is `true`, the
numeric values will be `bigint` instead of `number`.

```console
StatFs {
  type: 1397114950,
  bsize: 4096,
  frsize: 4096,
  blocks: 121938943,
  bfree: 61058895,
  bavail: 61058895,
  files: 999,
  ffree: 1000000
}
consolecopy
```

`bigint` version:

```console
StatFs {
  type: 1397114950n,
  bsize: 4096n,
  frsize: 4096n,
  blocks: 121938943n,
  bfree: 61058895n,
  bavail: 61058895n,
  files: 999n,
  ffree: 1000000n
}
consolecopy
```

#### statfs.bavail#

Added in: v19.6.0, v18.15.0
- Type: [<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<bigint>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#bigint_type)

Free blocks available to unprivileged users. Multiply by [statfs.bsize](#statfsbsize) to get the number of available bytes.

```mjs
import { statfs } from 'node:fs/promises';

const stats = await statfs('/');
const availableBytes = stats.bsize * stats.bavail;
console.log(`Available space: ${availableBytes} bytes`);
const { statfs } = require('node:fs/promises');

(async () => {
  const stats = await statfs('/');
  const availableBytes = stats.bsize * stats.bavail;
  console.log(`Available space: ${availableBytes} bytes`);
})();
javascriptcopy
```

#### statfs.bfree#

Added in: v19.6.0, v18.15.0
- Type: [<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<bigint>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#bigint_type)

Free blocks in file system. Multiply by [statfs.bsize](#statfsbsize) to get the number
of free bytes.

```mjs
import { statfs } from 'node:fs/promises';

const stats = await statfs('/');
const freeBytes = stats.bsize * stats.bfree;
console.log(`Free space: ${freeBytes} bytes`);
const { statfs } = require('node:fs/promises');

(async () => {
  const stats = await statfs('/');
  const freeBytes = stats.bsize * stats.bfree;
  console.log(`Free space: ${freeBytes} bytes`);
})();
javascriptcopy
```

#### statfs.blocks#

Added in: v19.6.0, v18.15.0
- Type: [<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<bigint>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#bigint_type)

Total data blocks in file system. Multiply by [statfs.bsize](#statfsbsize) to get the
total size in bytes.

```mjs
import { statfs } from 'node:fs/promises';

const stats = await statfs('/');
const totalBytes = stats.bsize * stats.blocks;
console.log(`Total space: ${totalBytes} bytes`);
const { statfs } = require('node:fs/promises');

(async () => {
  const stats = await statfs('/');
  const totalBytes = stats.bsize * stats.blocks;
  console.log(`Total space: ${totalBytes} bytes`);
})();
javascriptcopy
```

#### statfs.bsize#

Added in: v19.6.0, v18.15.0
- Type: [<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<bigint>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#bigint_type)

Optimal transfer block size in bytes.

#### statfs.frsize#

Added in: v26.1.0
- Type: [<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<bigint>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#bigint_type)

Fundamental file system block size.

#### statfs.ffree#

Added in: v19.6.0, v18.15.0
- Type: [<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<bigint>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#bigint_type)

Free file nodes in file system.

#### statfs.files#

Added in: v19.6.0, v18.15.0
- Type: [<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<bigint>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#bigint_type)

Total file nodes in file system.

#### statfs.type#

Added in: v19.6.0, v18.15.0
- Type: [<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<bigint>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#bigint_type)

Type of file system. A platform-specific numeric identifier for the type of
file system. This value corresponds to the `f_type` field returned by `statfs(2)` on POSIX systems (for example, `0xEF53` for ext4 on Linux). Its
meaning is OS-dependent and is not guaranteed to be consistent across
platforms.

#### Class: fs.Utf8Stream#

Added in: v24.6.0
Stability: 1 - Experimental

An optimized UTF-8 stream writer that allows for flushing all the internal
buffering on demand. It handles `EAGAIN` errors correctly, allowing for
customization, for example, by dropping content if the disk is busy.

#### Event: 'close'#

The `'close'` event is emitted when the stream is fully closed.

#### Event: 'drain'#

The `'drain'` event is emitted when the internal buffer has drained sufficiently
to allow continued writing.

#### Event: 'drop'#

The `'drop'` event is emitted when the maximal length is reached and that data
will not be written. The data that was dropped is passed as the first argument
to the event handler.

#### Event: 'error'#

The `'error'` event is emitted when an error occurs.

#### Event: 'finish'#

The `'finish'` event is emitted when the stream has been ended and all data has
been flushed to the underlying file.

#### Event: 'ready'#

The `'ready'` event is emitted when the stream is ready to accept writes.

#### Event: 'write'#

The `'write'` event is emitted when a write operation has completed. The number
of bytes written is passed as the first argument to the event handler.

#### new fs.Utf8Stream([options])#

- `options`[<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)
  - `append`: [<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) Appends writes to dest file instead of truncating it.**Default**: `true`.
  - `contentMode`: [<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) Which type of data you can send to the write
function, supported values are`'utf8'` or `'buffer'`. **Default**: `'utf8'`.
  - `dest`: [<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) A path to a file to be written to (mode controlled by the
append option).
  - `fd`: [<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) A file descriptor, something that is returned by`fs.open()` or `fs.openSync()`.
  - `fs`: [<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object) An object that has the same API as the`fs` module, useful
for mocking, testing, or customizing the behavior of the stream.
  - `fsync`: [<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) Perform a`fs.fsyncSync()` every time a write is
completed.
  - `maxLength`: [<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) The maximum length of the internal buffer. If a write
operation would cause the buffer to exceed`maxLength`, the data written is
dropped and a drop event is emitted with the dropped data
  - `maxWrite`: [<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) The maximum number of bytes that can be written;**Default**: `16384`
  - `minLength`: [<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) The minimum length of the internal buffer that is
required to be full before flushing.
  - `mkdir`: [<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) Ensure directory for`dest` file exists when true. **Default**: `false`.
  - `mode`: [<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) Specify the creating file mode (see`fs.open()`).
  - `periodicFlush`: [<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) Calls flush every`periodicFlush` milliseconds.
  - `retryEAGAIN`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function) A function that will be called when`write()`, `writeSync()`, or `flushSync()` encounters an `EAGAIN` or `EBUSY` error.
If the return value is `true` the operation will be retried, otherwise it
will bubble the error. The `err` is the error that caused this function to
be called, `writeBufferLen` is the length of the buffer that was written,
and `remainingBufferLen` is the length of the remaining buffer that the
stream did not try to write.
    - `err`[<any>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#Data_types) An error or`null`.
    - `writeBufferLen`[<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)
    - `remainingBufferLen`: [<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type)

  - `sync`: [<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) Perform writes synchronously.

#### utf8Stream.append#

- [<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) Whether the stream is appending to the file or truncating it.

#### utf8Stream.contentMode#

- [<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) The type of data that can be written to the stream. Supported
values are`'utf8'` or `'buffer'`. **Default**: `'utf8'`.

#### utf8Stream.destroy()#

Close the stream immediately, without flushing the internal buffer.

#### utf8Stream.end()#

Close the stream gracefully, flushing the internal buffer before closing.

#### utf8Stream.fd#

- [<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) The file descriptor that is being written to.

#### utf8Stream.file#

- [<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) The file that is being written to.

#### utf8Stream.flush(callback)#

- `callback`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function)
  - `err`[<Error>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Error) | [<null>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#null_type) An error if the flush failed, otherwise`null`.

Writes the current buffer to the file if a write was not in progress. Do
nothing if `minLength` is zero or if it is already writing.

#### utf8Stream.flushSync()#

Flushes the buffered data synchronously. This is a costly operation.

#### utf8Stream.fsync#

- [<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) Whether the stream is performing a`fs.fsyncSync()` after every
write operation.

#### utf8Stream.maxLength#

- [<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) The maximum length of the internal buffer. If a write
operation would cause the buffer to exceed`maxLength`, the data written is
dropped and a drop event is emitted with the dropped data.

#### utf8Stream.minLength#

- [<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) The minimum length of the internal buffer that is required to be
full before flushing.

#### utf8Stream.mkdir#

- [<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) Whether the stream should ensure that the directory for the`dest` file exists. If `true`, it will create the directory if it does not
exist. **Default**: `false`.

#### utf8Stream.mode#

- [<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) | [<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) The mode of the file that is being written to.

#### utf8Stream.periodicFlush#

- [<number>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) The number of milliseconds between flushes. If set to`0`, no
periodic flushes will be performed.

#### utf8Stream.reopen(file)#

- `file`: [<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) | [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api) A path to a file to be written to (mode
controlled by the append option).

Reopen the file in place, useful for log rotation.

#### utf8Stream.sync#

- [<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) Whether the stream is writing synchronously or asynchronously.

#### utf8Stream.write(data)#

- `data`[<string>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#string_type) | [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) The data to write.
- Returns [<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type)

When the `options.contentMode` is set to `'utf8'` when the stream is created,
the `data` argument must be a string. If the `contentMode` is set to `'buffer'`,
the `data`argument must be a [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer).

#### utf8Stream.writing#

- [<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type) Whether the stream is currently writing data to the file.

#### utf8Stream[Symbol.dispose]()#

Calls `utf8Stream.destroy()`.

#### Class: fs.WriteStream#

Added in: v0.1.93
- Extends [<stream.Writable>](https://nodejs.org/api/stream.html#class-streamwritable)

Instances of [<fs.WriteStream>](https://nodejs.org/api/fs.html#class-fswritestream) cannot be constructed directly. They are created and
returned using the[fs.createWriteStream()](#fscreatewritestreampath-options) function.

#### Event: 'close'#

Added in: v0.1.93
Emitted when the [<fs.WriteStream>](https://nodejs.org/api/fs.html#class-fswritestream)'s underlying file descriptor has been closed.

#### Event: 'open'#

Added in: v0.1.93
- `fd`[<integer>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#number_type) Integer file descriptor used by the [<fs.WriteStream>](https://nodejs.org/api/fs.html#class-fswritestream).

Emitted when the [<fs.WriteStream>](https://nodejs.org/api/fs.html#class-fswritestream)'s file is opened.

#### Event: 'ready'#

Added in: v9.11.0
Emitted when the [<fs.WriteStream>](https://nodejs.org/api/fs.html#class-fswritestream) is ready to be used.

Fires immediately after `'open'`.

#### writeStream.bytesWritten#

Added in: v0.4.7
The number of bytes written so far. Does not include data that is still queued
for writing.

#### writeStream.close([callback])#

Added in: v0.9.4
- `callback`[<Function>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Function)
  - `err`[<Error>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Error)

Closes `writeStream`. Optionally accepts a
callback that will be executed once the `writeStream` is closed.

#### writeStream.path#

Added in: v0.1.93
The path to the file the stream is writing to as specified in the first
argument to [fs.createWriteStream()](#fscreatewritestreampath-options). If `path` is passed as a string, then `writeStream.path` will be a string. If `path`is passed as a [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer), then`writeStream.path`will be a [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer).

#### writeStream.pending#

Added in: v11.2.0
- Type: [<boolean>](https://developer.mozilla.org/docs/Web/JavaScript/Data_structures#boolean_type)

This property is `true` if the underlying file has not been opened yet,
i.e. before the `'ready'` event is emitted.

#### fs.constants#

- Type: [<Object>](https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object)

Returns an object containing commonly used constants for file system
operations.

#### FS constants#

The following constants are exported by `fs.constants` and `fsPromises.constants`.

Not every constant will be available on every operating system;
this is especially important for Windows, where many of the POSIX specific
definitions are not available.
For portable applications it is recommended to check for their presence
before use.

To use more than one constant, use the bitwise OR `|` operator.

Example:

```mjs
import { open, constants } from 'node:fs';

const {
  O_RDWR,
  O_CREAT,
  O_EXCL,
} = constants;

open('/path/to/my/file', O_RDWR | O_CREAT | O_EXCL, (err, fd) => {
  // ...
});
mjscopy
```

#### File access constants#

The following constants are meant for use as the `mode` parameter passed to [fsPromises.access()](#fspromisesaccesspath-mode), [fs.access()](#fsaccesspath-mode-callback), and [fs.accessSync()](#fsaccesssyncpath-mode).

| Constant | Description |
| --- | --- |
| `F_OK` | Flag indicating that the file is visible to the calling process. This is useful for determining if a file exists, but says nothing about `rwx` permissions. Default if no mode is specified. |
| `R_OK` | Flag indicating that the file can be read by the calling process. |
| `W_OK` | Flag indicating that the file can be written by the calling process. |
| `X_OK` | Flag indicating that the file can be executed by the calling process. This has no effect on Windows (will behave like `fs.constants.F_OK`). |

The definitions are also available on Windows.

#### File copy constants#

The following constants are meant for use with [fs.copyFile()](#fscopyfilesrc-dest-mode-callback).

| Constant | Description |
| --- | --- |
| `COPYFILE_EXCL` | If present, the copy operation will fail with an error if the destination path already exists. |
| `COPYFILE_FICLONE` | If present, the copy operation will attempt to create a copy-on-write reflink. If the underlying platform does not support copy-on-write, then a fallback copy mechanism is used. |
| `COPYFILE_FICLONE_FORCE` | If present, the copy operation will attempt to create a copy-on-write reflink. If the underlying platform does not support copy-on-write, then the operation will fail with an error. |

The definitions are also available on Windows.

#### File open constants#

The following constants are meant for use with `fs.open()`.

| Constant | Description |
| --- | --- |
| `O_RDONLY` | Flag indicating to open a file for read-only access. |
| `O_WRONLY` | Flag indicating to open a file for write-only access. |
| `O_RDWR` | Flag indicating to open a file for read-write access. |
| `O_CREAT` | Flag indicating to create the file if it does not already exist. |
| `O_EXCL` | Flag indicating that opening a file should fail if the `O_CREAT` flag is set and the file already exists. |
| `O_NOCTTY` | Flag indicating that if path identifies a terminal device, opening the path shall not cause that terminal to become the controlling terminal for the process (if the process does not already have one). |
| `O_TRUNC` | Flag indicating that if the file exists and is a regular file, and the file is opened successfully for write access, its length shall be truncated to zero. |
| `O_APPEND` | Flag indicating that data will be appended to the end of the file. |
| `O_DIRECTORY` | Flag indicating that the open should fail if the path is not a directory. |
| `O_NOATIME` | Flag indicating reading accesses to the file system will no longer result in an update to the `atime` information associated with the file. This flag is available on Linux operating systems only. |
| `O_NOFOLLOW` | Flag indicating that the open should fail if the path is a symbolic link. |
| `O_SYNC` | Flag indicating that the file is opened for synchronized I/O with write operations waiting for file integrity. |
| `O_DSYNC` | Flag indicating that the file is opened for synchronized I/O with write operations waiting for data integrity. |
| `O_SYMLINK` | Flag indicating to open the symbolic link itself rather than the resource it is pointing to. |
| `O_DIRECT` | When set, an attempt will be made to minimize caching effects of file I/O. |
| `O_NONBLOCK` | Flag indicating to open the file in nonblocking mode when possible. |
| `UV_FS_O_FILEMAP` | When set, a memory file mapping is used to access the file. This flag is available on Windows operating systems only. On other operating systems, this flag is ignored. |

On Windows, only `O_APPEND`, `O_CREAT`, `O_EXCL`, `O_RDONLY`, `O_RDWR`, `O_TRUNC`, `O_WRONLY`, and `UV_FS_O_FILEMAP` are available.

#### File type constants#

The following constants are meant for use with the [<fs.Stats>](https://nodejs.org/api/fs.html#class-fsstats) object's`mode` property for determining a file's type.

| Constant | Description |
| --- | --- |
| `S_IFMT` | Bit mask used to extract the file type code. |
| `S_IFREG` | File type constant for a regular file. |
| `S_IFDIR` | File type constant for a directory. |
| `S_IFCHR` | File type constant for a character-oriented device file. |
| `S_IFBLK` | File type constant for a block-oriented device file. |
| `S_IFIFO` | File type constant for a FIFO/pipe. |
| `S_IFLNK` | File type constant for a symbolic link. |
| `S_IFSOCK` | File type constant for a socket. |

On Windows, only `S_IFCHR`, `S_IFDIR`, `S_IFLNK`, `S_IFMT`, and `S_IFREG`,
are available.

#### File mode constants#

The following constants are meant for use with the [<fs.Stats>](https://nodejs.org/api/fs.html#class-fsstats) object's`mode` property for determining the access permissions for a file.

| Constant | Description |
| --- | --- |
| `S_IRWXU` | File mode indicating readable, writable, and executable by owner. |
| `S_IRUSR` | File mode indicating readable by owner. |
| `S_IWUSR` | File mode indicating writable by owner. |
| `S_IXUSR` | File mode indicating executable by owner. |
| `S_IRWXG` | File mode indicating readable, writable, and executable by group. |
| `S_IRGRP` | File mode indicating readable by group. |
| `S_IWGRP` | File mode indicating writable by group. |
| `S_IXGRP` | File mode indicating executable by group. |
| `S_IRWXO` | File mode indicating readable, writable, and executable by others. |
| `S_IROTH` | File mode indicating readable by others. |
| `S_IWOTH` | File mode indicating writable by others. |
| `S_IXOTH` | File mode indicating executable by others. |

On Windows, only `S_IRUSR` and `S_IWUSR` are available.

### Notes#

#### Ordering of callback and promise-based operations#

Because they are executed asynchronously by the underlying thread pool,
there is no guaranteed ordering when using either the callback or
promise-based methods.

For example, the following is prone to error because the `fs.stat()` operation might complete before the `fs.rename()` operation:

```js
const fs = require('node:fs');

fs.rename('/tmp/hello', '/tmp/world', (err) => {
  if (err) throw err;
  console.log('renamed complete');
});
fs.stat('/tmp/world', (err, stats) => {
  if (err) throw err;
  console.log(`stats: ${JSON.stringify(stats)}`);
});
jscopy
```

It is important to correctly order the operations by awaiting the results
of one before invoking the other:

```mjs
import { rename, stat } from 'node:fs/promises';

const oldPath = '/tmp/hello';
const newPath = '/tmp/world';

try {
  await rename(oldPath, newPath);
  const stats = await stat(newPath);
  console.log(`stats: ${JSON.stringify(stats)}`);
} catch (error) {
  console.error('there was an error:', error.message);
}
const { rename, stat } = require('node:fs/promises');

(async function(oldPath, newPath) {
  try {
    await rename(oldPath, newPath);
    const stats = await stat(newPath);
    console.log(`stats: ${JSON.stringify(stats)}`);
  } catch (error) {
    console.error('there was an error:', error.message);
  }
})('/tmp/hello', '/tmp/world');
javascriptcopy
```

Or, when using the callback APIs, move the `fs.stat()` call into the callback
of the `fs.rename()` operation:

```mjs
import { rename, stat } from 'node:fs';

rename('/tmp/hello', '/tmp/world', (err) => {
  if (err) throw err;
  stat('/tmp/world', (err, stats) => {
    if (err) throw err;
    console.log(`stats: ${JSON.stringify(stats)}`);
  });
});
const { rename, stat } = require('node:fs/promises');

rename('/tmp/hello', '/tmp/world', (err) => {
  if (err) throw err;
  stat('/tmp/world', (err, stats) => {
    if (err) throw err;
    console.log(`stats: ${JSON.stringify(stats)}`);
  });
});
javascriptcopy
```

#### File paths#

Most `fs`operations accept file paths that may be specified in the form of
a string, a [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer), or a [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api) object using the`file:` protocol.

#### String paths#

String paths are interpreted as UTF-8 character sequences identifying
the absolute or relative filename. Relative paths will be resolved relative
to the current working directory as determined by calling `process.cwd()`.

Example using an absolute path on POSIX:

```mjs
import { open } from 'node:fs/promises';

let fd;
try {
  fd = await open('/open/some/file.txt', 'r');
  // Do something with the file
} finally {
  await fd?.close();
}
mjscopy
```

Example using a relative path on POSIX (relative to `process.cwd()`):

```mjs
import { open } from 'node:fs/promises';

let fd;
try {
  fd = await open('file.txt', 'r');
  // Do something with the file
} finally {
  await fd?.close();
}
mjscopy
```

#### File URL paths#

Added in: v7.6.0
For most `node:fs` module functions, the `path` or `filename`argument may be
passed as a [<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api) object using the`file:` protocol.

```mjs
import { readFileSync } from 'node:fs';

readFileSync(new URL('file:///tmp/hello'));
mjscopy
```

`file:` URLs are always absolute paths.

#### Platform-specific considerations#

On Windows, `file:`[<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)s with a host name convert to UNC paths, while`file:`[<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)s with drive letters convert to local absolute paths.`file:`[<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)s
with no host name and no drive letter will result in an error:

```mjs
import { readFileSync } from 'node:fs';
// On Windows :

// - WHATWG file URLs with hostname convert to UNC path
// file://hostname/p/a/t/h/file => \\hostname\p\a\t\h\file
readFileSync(new URL('file://hostname/p/a/t/h/file'));

// - WHATWG file URLs with drive letters convert to absolute path
// file:///C:/tmp/hello => C:\tmp\hello
readFileSync(new URL('file:///C:/tmp/hello'));

// - WHATWG file URLs without hostname must have a drive letters
readFileSync(new URL('file:///notdriveletter/p/a/t/h/file'));
readFileSync(new URL('file:///c/p/a/t/h/file'));
// TypeError [ERR_INVALID_FILE_URL_PATH]: File URL path must be absolute
mjscopy
```

`file:`[<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)s with drive letters must use`:` as a separator just after
the drive letter. Using another separator will result in an error.

On all other platforms, `file:`[<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)s with a host name are unsupported and
will result in an error:

```mjs
import { readFileSync } from 'node:fs';
// On other platforms:

// - WHATWG file URLs with hostname are unsupported
// file://hostname/p/a/t/h/file => throw!
readFileSync(new URL('file://hostname/p/a/t/h/file'));
// TypeError [ERR_INVALID_FILE_URL_PATH]: must be absolute

// - WHATWG file URLs convert to absolute path
// file:///tmp/hello => /tmp/hello
readFileSync(new URL('file:///tmp/hello'));
mjscopy
```

A `file:`[<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api) having encoded slash characters will result in an error on all
platforms:

```mjs
import { readFileSync } from 'node:fs';

// On Windows
readFileSync(new URL('file:///C:/p/a/t/h/%2F'));
readFileSync(new URL('file:///C:/p/a/t/h/%2f'));
/* TypeError [ERR_INVALID_FILE_URL_PATH]: File URL path must not include encoded
\ or / characters */

// On POSIX
readFileSync(new URL('file:///p/a/t/h/%2F'));
readFileSync(new URL('file:///p/a/t/h/%2f'));
/* TypeError [ERR_INVALID_FILE_URL_PATH]: File URL path must not include encoded
/ characters */
mjscopy
```

On Windows, `file:`[<URL>](https://nodejs.org/api/url.html#the-whatwg-url-api)s having encoded backslash will result in an error:

```mjs
import { readFileSync } from 'node:fs';

// On Windows
readFileSync(new URL('file:///C:/path/%5C'));
readFileSync(new URL('file:///C:/path/%5c'));
/* TypeError [ERR_INVALID_FILE_URL_PATH]: File URL path must not include encoded
\ or / characters */
mjscopy
```

#### Buffer paths#

Paths specified using a [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) are useful primarily on certain POSIX
operating systems that treat file paths as opaque byte sequences. On such
systems, it is possible for a single file path to contain sub-sequences that
use multiple character encodings. As with string paths, [<Buffer>](https://nodejs.org/api/buffer.html#class-buffer) paths may
be relative or absolute:

Example using an absolute path on POSIX:

```mjs
import { open } from 'node:fs/promises';
import { Buffer } from 'node:buffer';

let fd;
try {
  fd = await open(Buffer.from('/open/some/file.txt'), 'r');
  // Do something with the file
} finally {
  await fd?.close();
}
mjscopy
```

#### Per-drive working directories on Windows#

On Windows, Node.js follows the concept of per-drive working directory. This
behavior can be observed when using a drive path without a backslash. For
example `fs.readdirSync('C:\\')` can potentially return a different result than `fs.readdirSync('C:')`. For more information, see [this MSDN page](https://docs.microsoft.com/en-us/windows/desktop/FileIO/naming-a-file#fully-qualified-vs-relative-paths).

#### File descriptors#

On POSIX systems, for every process, the kernel maintains a table of currently
open files and resources. Each open file is assigned a simple numeric
identifier called a _file descriptor_. At the system-level, all file system
operations use these file descriptors to identify and track each specific
file. Windows systems use a different but conceptually similar mechanism for
tracking resources. To simplify things for users, Node.js abstracts away the
differences between operating systems and assigns all open files a numeric file
descriptor.

The callback-based `fs.open()`, and synchronous `fs.openSync()` methods open a
file and allocate a new file descriptor. Once allocated, the file descriptor may
be used to read data from, write data to, or request information about the file.

Operating systems limit the number of file descriptors that may be open
at any given time so it is critical to close the descriptor when operations
are completed. Failure to do so will result in a memory leak that will
eventually cause an application to crash.

```mjs
import { open, close, fstat } from 'node:fs';

function closeFd(fd) {
  close(fd, (err) => {
    if (err) throw err;
  });
}

open('/open/some/file.txt', 'r', (err, fd) => {
  if (err) throw err;
  try {
    fstat(fd, (err, stat) => {
      if (err) {
        closeFd(fd);
        throw err;
      }

      // use stat

      closeFd(fd);
    });
  } catch (err) {
    closeFd(fd);
    throw err;
  }
});
mjscopy
```

The promise-based APIs use a [<FileHandle>](https://nodejs.org/api/fs.html#class-filehandle) object in place of the numeric
file descriptor. These objects are better managed by the system to ensure
that resources are not leaked. However, it is still required that they are
closed when operations are completed:

```mjs
import { open } from 'node:fs/promises';

let file;
try {
  file = await open('/open/some/file.txt', 'r');
  const stat = await file.stat();
  // use stat
} finally {
  await file.close();
}
mjscopy
```

#### Threadpool usage#

All callback and promise-based file system APIs (with the exception of `fs.FSWatcher()`) use libuv's threadpool. This can have surprising and negative
performance implications for some applications. See the [UV_THREADPOOL_SIZE](https://nodejs.org/api/cli.html#uv_threadpool_sizesize) documentation for more information.

#### File system flags#

The following flags are available wherever the `flag` option takes a
string.

- `'a'`: Open file for appending.
The file is created if it does not exist.

- `'ax'`: Like `'a'` but fails if the path exists.

- `'a+'`: Open file for reading and appending.
The file is created if it does not exist.

- `'ax+'`: Like `'a+'` but fails if the path exists.

- `'as'`: Open file for appending in synchronous mode.
The file is created if it does not exist.

- `'as+'`: Open file for reading and appending in synchronous mode.
The file is created if it does not exist.

- `'r'`: Open file for reading.
An exception occurs if the file does not exist.

- `'rs'`: Open file for reading in synchronous mode.
An exception occurs if the file does not exist.

- `'r+'`: Open file for reading and writing.
An exception occurs if the file does not exist.

- `'rs+'`: Open file for reading and writing in synchronous mode. Instructs
the operating system to bypass the local file system cache.
This is primarily useful for opening files on NFS mounts as it allows
skipping the potentially stale local cache. It has a very real impact on
I/O performance so using this flag is not recommended unless it is needed.
This doesn't turn `fs.open()` or `fsPromises.open()` into a synchronous
blocking call. If synchronous operation is desired, something like `fs.openSync()` should be used.

- `'w'`: Open file for writing.
The file is created (if it does not exist) or truncated (if it exists).

- `'wx'`: Like `'w'` but fails if the path exists.

- `'w+'`: Open file for reading and writing.
The file is created (if it does not exist) or truncated (if it exists).

- `'wx+'`: Like `'w+'` but fails if the path exists.

`flag`can also be a number as documented by [open(2)](http://man7.org/linux/man-pages/man2/open.2.html); commonly used constants
are available from`fs.constants`. On Windows, flags are translated to
their equivalent ones where applicable, e.g. `O_WRONLY` to `FILE_GENERIC_WRITE`,
or `O_EXCL|O_CREAT` to `CREATE_NEW`, as accepted by `CreateFileW`.

The exclusive flag `'x'` (`O_EXCL`flag in [open(2)](http://man7.org/linux/man-pages/man2/open.2.html)) causes the operation to
return an error if the path already exists. On POSIX, if the path is a symbolic
link, using`O_EXCL` returns an error even if the link is to a path that does
not exist. The exclusive flag might not work with network file systems.

On Linux, positional writes don't work when the file is opened in append mode.
The kernel ignores the position argument and always appends the data to
the end of the file.

Modifying a file rather than replacing it may require the `flag` option to be
set to `'r+'` rather than the default `'w'`.

The behavior of some flags are platform-specific. As such, opening a directory
on macOS and Linux with the `'a+'` flag, as in the example below, will return an
error. In contrast, on Windows and FreeBSD, a file descriptor or a `FileHandle` will be returned.

```js
// macOS and Linux
fs.open('<directory>', 'a+', (err, fd) => {
  // => [Error: EISDIR: illegal operation on a directory, open <directory>]
});

// Windows and FreeBSD
fs.open('<directory>', 'a+', (err, fd) => {
  // => null, <fd>
});
jscopy
```

On Windows, opening an existing hidden file using the `'w'` flag (either
through `fs.open()`, `fs.writeFile()`, or `fsPromises.open()`) will fail with `EPERM`. Existing hidden files can be opened for writing with the `'r+'` flag.

A call to `fs.ftruncate()` or `filehandle.truncate()` can be used to reset
the file contents.