export class PackedSlice {
  #type;
  #bits;
  #value;
  #memory;
  #valid;

  constructor(type, bits, value, memory) {
    this.#type = type; // one of: uint, int, float
    this.#bits = bits; // one of: 8, 16, 32, 64
    this.#value = value; // packed slice representation
    this.#memory = memory; // WebAssembly exported memory
    this.#valid = true;

    if (typeof(this.#type) != 'string' || this.#type.length == 0) {
      throw new Error("type must be a non-empty string");
    }
    
    if (typeof(this.#bits) != 'number' || !Number.isInteger(this.#bits)) {
      throw new Error("bits must be an integer");
    }
    
    if (typeof(this.#value) != 'bigint') {
      throw new Error("value must be a bigint");
    }
    
    if (!(this.#memory instanceof WebAssembly.Memory)) {
      throw new Error("memory must be an instance of WebAssembly.Memory");
    }

    console.assert(this.arrayType, "invalid combination of type and bits");
    console.assert(this.pointer != 0, "packed slice has zero pointer: %d", this.#value);
    console.assert(this.length != 0, "packed slice has zero length: %d", this.#value);
  }

  get value() {
    return this.#value;
  }

  get pointer() {
    // XXX: assumes wasm32 so usize would be 32 bits
    return Number(BigInt(this.#value) & 0xffffffffn);
  }

  get length() {
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

  get arrayType() {
    // https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/TypedArray
    // https://stackoverflow.com/a/21820040
    switch (this.#type) {
      case 'uint':
      case 'int':
        const signed = (this.#type === 'int');
        switch (this.#bits) {
          case 8:  return signed ? Int8Array     : Uint8Array;
          case 16: return signed ? Int16Array    : Uint16Array;
          case 32: return signed ? Int32Array    : Uint32Array;
          case 64: return signed ? BigInt64Array : BigUint64Array;
          default: throw new Error(`unsupported integer bit width: ${this.#bits}`);
        }

      case 'float':
        switch (this.#bits) {
          case 32: return Float32Array;
          case 64: return Float64Array;
          default: throw new Error(`unsupported float bit width: ${this.#bits}`);
        }

      default: throw new Error(`unsupported type: ${this.#type}`);
    }

    // should return or throw before we ever make it here
    throw new Error("unreachable: logic error");
  }

  get array() {
    // prevent accessing invalid slice data (ex: after it has been freed)
    if (!this.#valid) {
      throw new Error("attempt to access invalid slice data");
    }

    // retrieve the buffer on demand in case it's been replaced with a new instance
    return new this.arrayType(this.#memory.buffer, this.pointer, this.length);
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

  allocateBytes(size) {
    if (typeof(size) != 'number' || !Number.isInteger(size) || size <= 0) {
      throw new Error("size must be a positive integer");
    }

    const exports = this.#instance.exports;
    const value = exports.allocBytes(size);
    return new PackedSlice('uint', 8, value, exports.memory);
  }

  freeBytes(slice) {
    if (!(slice instanceof PackedSlice)) {
      throw new Error("slice must be an instance of PackedSlice");
    }

    this.#instance.exports.freeBytes(slice.value);
    slice.invalidate();
  }
}

export class ClientLoader {
  #sourceUrl;
  #importObject;
  #compileOptions;
  #clientResolve;
  #clientReject;

  constructor(sourceUrl, importObject, compileOptions) {
    this.#sourceUrl = sourceUrl; // URL()
    this.#importObject = Object.assign({}, importObject); // Object()
    this.#compileOptions = Object.assign({}, compileOptions); // Object()

    if (!(this.#sourceUrl instanceof URL)) {
      throw new Error("sourceUrl must be an instance of URL");
    }

    this.client = new Promise((resolve, reject) => {
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
