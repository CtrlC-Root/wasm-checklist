export class TypedArraySpecification {
  #value;
  #arrayType;
  #signed;

  constructor(value) {
    this.#value = value;

    const [arrayType, signed] = (function(value) {
      switch (value) {
        case 'uint8':   return [Uint8Array,     false];
        case 'uint16':  return [Uint16Array,    false];
        case 'uint32':  return [Uint32Array,    false];
        case 'uint64':  return [BigUint64Array, false];
    
        case 'int8':    return [Int8Array,      true];
        case 'int16':   return [Int16Array,     true];
        case 'int32':   return [Int32Array,     true];
        case 'int64':   return [BigInt64Array,  true];

        case 'float32': return [Float32Array,   true];
        case 'float64': return [Float64Array,   true];

        default: throw new Error(`unsupported typed array specification: ${value}`);
      }
    })(this.#value);

    this.#arrayType = arrayType;
    this.#signed = signed;
  }

  get arrayType() {
    return this.#arrayType;
  }

  get signed() {
    return this.#signed;
  }
}

export class PackedSlice {
  #memory; // WebAssembly.Memory instance
  #value;  // BigInt representing a client PackedSlice value
  #valid;  // true if pointer into memory is valid

  constructor(memory, value) {
    this.#memory = memory;
    this.#value = value;
    this.#valid = true;

    if (!(this.#memory instanceof WebAssembly.Memory)) {
      throw new Error("memory must be WebAssembly.Memory() instance");
    }

    if (typeof(this.#value) != 'bigint') {
      throw new Error("value must be a BigInt");
    }

    console.assert(this.pointer != 0, "packed slice has zero pointer: %d", this.#value);
    console.assert(this.byteLength != 0, "packed slice has zero length: %d", this.#value);
  }

  get memory() {
    return this.#memory;
  }

  get value() {
    return this.#value;
  }

  get pointer() {
    // XXX: assumes wasm32 so usize would be 32 bits
    return Number(BigInt(this.#value) & 0xffffffffn);
  }

  get byteLength() {
    // XXX: assumes wasm32 so usize would be 32 bits
    return Number(BigInt(this.#value) >> 32n);
  }

  get valid() {
    return this.#valid;
  }

  invalidate() {
    console.assert(this.#valid, "slice is not valid");
    this.#valid = false;
  }
}

export class ClientArrayBuffer {
  #specification; // TypedArraySpecification instance
  #localBuffer;   // null or ArrayBuffer() instance
  #remoteSlice;   // null or PackedSlice() instance

  constructor(specification, buffer_or_slice) {
    this.#specification = specification;
    if (!(this.#specification instanceof TypedArraySpecification)) {
      throw new Error("specification must be a TypedArraySpecification instance");
    }

    if (buffer_or_slice instanceof ArrayBuffer) {
      this.#localBuffer = buffer_or_slice;
      this.#remoteSlice = null;

      // XXX: validate this.#localBuffer.byteLength is multiple of this.#specification.bytes
      // TODO: invariants for resizable array buffers?
    } else if (buffer_or_slice instanceof PackedSlice) {
      this.#localBuffer = null;
      this.#remoteSlice = buffer_or_slice;

      // XXX: validate this.#remoteSlice.byteLength is multiple of this.#specification.bytes
    } else {
      throw new Error("buffer_or_slice must be an instance of ArrayBuffer or PackedSlice");
    }
  }

  get specification() {
    return this.#specification;
  }

  get isLocal() {
    return this.#localBuffer != null;
  }

  get isRemote() {
    return this.#remoteSlice != null;
  }

  get slice() {
    if (!this.isRemote) {
      throw new Error("buffer is not remote");
    }

    return this.#remoteSlice;
  }

  get byteLength() {
    if (this.#localBuffer != null) {
      console.assert(this.#remoteSlice == null);
      return this.#localBuffer.byteLength;
    } else {
      console.assert(this.#localBuffer == null);
      return this.#remoteSlice.byteLength;
    }
  }

  get array() {
    const arrayType = this.#specification.arrayType;
    if (this.#localBuffer != null) {
      console.assert(this.#remoteSlice == null);
      return new arrayType(this.#localBuffer);
    } else {
      console.assert(this.#localBuffer == null);
      return new arrayType(
        this.#remoteSlice.memory.buffer,
        this.#remoteSlice.pointer,
        this.#remoteSlice.byteLength / arrayType.BYTES_PER_ELEMENT
      );
    }
  }

  exchangeWithLocal(buffer) {
    if (!(buffer instanceof ArrayBuffer)) {
      throw new Error("buffer must be an ArrayBuffer instance");
    }

    if (this.isLocal) {
      throw new Error("client array buffer is already local");
    }

    console.assert(this.isRemote);

    if (this.byteLength != buffer.byteLength) {
      throw new Error("client array buffer and local buffer have different byte lengths");
    }

    const sliceArray = this.array;
    const slice = this.#remoteSlice;
    this.#remoteSlice = null;
    this.#localBuffer = buffer;
    this.array.set(sliceArray);

    return slice;
  }

  exchangeWithRemote(slice) {
    if (!(slice instanceof PackedSlice)) {
      throw new Error("slice must be a PackedSlice instance");
    }

    if (this.isRemote) {
      throw new Error("client array buffer is already remote");
    }

    console.assert(this.isLocal);

    if (this.byteLength != slice.byteLength) {
      throw new Error("client array buffer and slice have different byte lengths");
    }

    const bufferArray = this.array;
    const buffer = this.#localBuffer;
    this.#localBuffer = null;
    this.#remoteSlice = slice;
    this.array.set(bufferArray);

    return buffer;
  }
}

export class Client {
  #instance;

  constructor(instance) {
    this.#instance = instance;

    if (!(this.#instance instanceof WebAssembly.Instance)) {
      throw new Error("instance must be an instance of WebAssembly.Instance");
    }

    // initialize internal client state
    this.#instance.exports.initialize();
  }

  // XXX: DEBUG only?
  get instance() {
    return this.#instance;
  }

  allocateBytes(size) {
    if (typeof(size) != 'number' || !Number.isInteger(size) || size <= 0) {
      throw new Error("size must be a positive integer");
    }

    const exports = this.#instance.exports;
    return new PackedSlice(exports.memory, exports.allocBytes(size));
  }

  freeBytes(slice) {
    if (!(slice instanceof PackedSlice)) {
      throw new Error("slice must be an instance of PackedSlice");
    }

    this.#instance.exports.freeBytes(slice.value);
    slice.invalidate();
  }

  allocateArrayBuffer(specification, length) {
    if (!(specification instanceof TypedArraySpecification)) {
      throw new Error("specification must be a TypedArraySpecification instance");
    }

    const slice = this.allocateBytes(specification.bytes * length);
    return new ClientArrayBuffer(specification, slice);
  }

  moveArrayBufferIn(clientArrayBuffer) {
    if (!(clientArrayBuffer instanceof ClientArrayBuffer)) {
      throw new Error("clientArrayBuffer must be a ClientArrayBuffer instance");
    }

    if (clientArrayBuffer.isLocal) {
      const slice = this.allocateBytes(clientArrayBuffer.byteLength);
      const arrayBuffer = clientArrayBuffer.exchangeWithRemote(slice);
    } else {
      console.assert(clientArrayBuffer.isRemote());
      // XXX: handle moving buffer between different clients maybe?
      throw new Error("clientArrayBuffer is already remote");
    }
  }

  moveArrayBufferOut(clientArrayBuffer) {
    if (!(clientArrayBuffer instanceof ClientArrayBuffer)) {
      throw new Error("clientArrayBuffer must be a ClientArrayBuffer instance");
    }

    // XXX: confirm buffer slice points to this client's memory
    if (clientArrayBuffer.isRemote) {
      const arrayBuffer = new ArrayBuffer(clientArrayBuffer.byteLength);
      const slice = clientArrayBuffer.exchangeWithLocal(arrayBuffer);
      this.freeBytes(slice);
    } else {
      console.assert(clientArrayBuffer.isLocal());
      throw new Error("clientArrayBuffer is already local");
    }
  }
}

export class ClientLoader {
  #sourceUrl;
  #importObject;
  #compileOptions;
  #client;
  #clientResolve;
  #clientReject;

  constructor(sourceUrl, importObject, compileOptions) {
    this.#sourceUrl = sourceUrl; // URL()
    this.#importObject = Object.assign({}, importObject); // Object()
    this.#compileOptions = Object.assign({}, compileOptions); // Object()

    if (!(this.#sourceUrl instanceof URL)) {
      throw new Error("sourceUrl must be an instance of URL");
    }

    this.#client = new Promise((resolve, reject) => {
      this.#clientResolve = resolve;
      this.#clientReject = reject;
    });
  }

  get sourceUrl() {
    return this.#sourceUrl;
  }

  get importObject() {
    return this.#importObject;
  }

  get compileOptions() {
    return this.#compileOptions;
  }

  get client() {
    return this.#client;
  }

  async load() {
    try {
      const result = await WebAssembly.instantiateStreaming(
        fetch(this.#sourceUrl.toString()),
        this.#importObject,
        this.#compileOptions
      );

      const client = new Client(result.instance);

      this.#clientResolve(client);
      return client;
    }
    catch (error) {
      this.#clientReject(error);
      throw error;
    }
  }
}

export default {
  TypedArraySpecification: TypedArraySpecification,
  PackedSlice: PackedSlice,
  ClientArrayBuffer: ClientArrayBuffer,
  Client: Client,
  ClientLoader: ClientLoader,
};
