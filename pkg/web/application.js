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

    if (typeof(this.#value) !== 'bigint') {
      throw new Error("value must be a BigInt instance");
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

export class DataBuffer {
  // A TypedArray type or DataView used to access referenced memory.
  // https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/TypedArray
  // https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/DataView
  #dataType;

  // Indirect reference to a slice of WebAssembly.Memory.
  #packedSlice;

  // Direct reference to an ArrayBuffer or SharedArrayBuffer.
  // https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/ArrayBuffer
  // https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/SharedArrayBuffer
  #arrayBuffer;

  // XXX: utility to validate dataType
  static describeDataType(dataType) {
    switch (Object.getPrototypeOf(dataType)) {
      case Object.getPrototypeOf(Uint8Array):
      case Object.getPrototypeOf(Uint16Array):
      case Object.getPrototypeOf(Uint32Array):
        return [Number, false, dataType.BYTES_PER_ELEMENT];

      case Object.getPrototypeOf(Int8Array):
      case Object.getPrototypeOf(Int16Array):
      case Object.getPrototypeOf(Int32Array):
        return [Number, true, dataType.BYTES_PER_ELEMENT];

      case Object.getPrototypeOf(BigUint64Array):
        return [BigInt, false, dataType.BYTES_PER_ELEMENT];

      case Object.getPrototypeOf(BigInt64Array):
        return [BigInt, true, dataType.BYTES_PER_ELEMENT];

      case Object.getPrototypeOf(DataView):
        return [null, null, null];
    }

    throw new Error(`unsupported data type: ${dataType}`);
  }

  constructor(dataType, value) {
    this.#dataType = dataType;
    DataBuffer.describeDataType(this.#dataType);

    if (value instanceof ArrayBuffer) {
      this.#packedSlice = null;
      this.#arrayBuffer = value;
    } else if (typeof(SharedArrayBuffer) !== 'undefined' && value instanceof SharedArrayBuffer) {
      this.#packedSlice = null;
      this.#arrayBuffer = value;
    } else if (value instanceof PackedSlice) {
      this.#packedSlice = value;
      this.#arrayBuffer = null;
    } else {
      throw new Error(`unsupported data buffer value: ${value}`);
    }
  }

  get dataType() {
    return this.#dataType;
  }

  get isPackedSlice() {
    return (this.#packedSlice != null);
  }

  get packedSlice() {
    if (this.#packedSlice == null) {
      throw new Error("data buffer is not referencing a packed slice");
    }

    return this.#packedSlice;
  }

  get resizable() {
    if (this.#packedSlice != null) {
      console.assert(this.#arrayBuffer == null);
      return false;
    }

    console.assert(this.#arrayBuffer != null);
    if (this.#arrayBuffer instanceof ArrayBuffer) {
      return this.#arrayBuffer.resizable;
    }

    console.assert(typeof(SharedArrayBuffer) !== 'undefined');
    console.assert(this.#arrayBuffer instanceof SharedArrayBuffer);
    return false; // SharedArrayBuffer may only growable, not resizable
  }

  get growable() {
    if (this.#packedSlice != null) {
      console.assert(this.#arrayBuffer == null);
      return false;
    }

    console.assert(this.#arrayBuffer != null);
    if (typeof(SharedArrayBuffer) !== 'undefined' && this.#arrayBuffer instanceof SharedArrayBuffer) {
      return this.#arrayBuffer.growable;
    }

    console.assert(this.#arrayBuffer instanceof ArrayBuffer);
    return this.#arrayBuffer.resizable;
  }

  get data() {
    if (this.#packedSlice != null) {
      console.assert(this.#arrayBuffer == null);
      console.assert(this.#packedSlice.valid);

      const slice = this.#packedSlice;
      if (Object.getPrototypeOf(this.#dataType) == Object.getPrototypeOf(DataView)) {
        return new this.#dataType(
          slice.memory.buffer,
          slice.pointer,
          slice.byteLength
        );
      }

      // account for array element size in bytes
      return new this.#dataType(
        slice.memory.buffer,
        slice.pointer,
        // XXX: validate this is integer division with no remainder
        slice.byteLength / this.#dataType.BYTES_PER_ELEMENT
      );
    } else {
      console.assert(this.#packedSlice == null);
      return new this.#dataType(this.#arrayBuffer);
    }
  }

  get byteLength() {
    if (this.#packedSlice != null) {
      console.assert(this.#arrayBuffer == null);
      return this.#packedSlice.byteLength;
    } else {
      console.assert(this.#packedSlice == null);
      return this.#arrayBuffer.byteLength;
    }
  }

  exchangeWithPackedSlice(packedSlice) {
    if (!(packedSlice instanceof PackedSlice)) {
      throw new Error("packedSlice must be a PackedSlice instance");
    }

    if (this.#packedSlice != null) {
      throw new Error("data buffer is already referencing a packed slice");
    }

    console.assert(this.#arrayBuffer != null);
    if (this.#arrayBuffer.byteLength != packedSlice.byteLength) {
      throw new Error("data buffer and packed slice have different byte lengths");
    }

    const existingData = this.data;
    const arrayBuffer = this.#arrayBuffer;
    this.#arrayBuffer = null;
    this.#packedSlice = packedSlice;
    this.data.set(existingData); // TODO: what about DataView?

    return arrayBuffer;
  }

  exchangeWithArrayBuffer(arrayBuffer) {
    const arrayBufferCheck = (arrayBuffer instanceof ArrayBuffer);
    const sharedArrayBufferCheck = (typeof(SharedArrayBuffer) !== 'undefined' && arrayBuffer instanceof SharedArrayBuffer);
    if (!arrayBufferCheck && !sharedArrayBufferCheck) {
      throw new Error("arrayBuffer must be an ArrayBuffer or SharedArrayBuffer instance");
    }

    if (this.#arrayBuffer != null) {
      throw new Error("data buffer is already referencing an array buffer");
    }

    console.assert(this.#packedSlice != null);
    if (this.#packedSlice.byteLength != arrayBuffer.byteLength) {
      // XXX: maybe support copying data into a larger buffer than we need?
      throw new Error("data buffer slice and array buffer have different byte lengths");
    }

    const existingData = this.data;
    const packedSlice = this.#packedSlice;
    this.#packedSlice = null;
    this.#arrayBuffer = arrayBuffer;
    this.data.set(existingData); // TODO: what about DataView?

    return packedSlice;
  }
}

export class Application {
  #instance;
  #textEncoder;
  #textDecoder;

  constructor(instance) {
    this.#instance = instance;

    if (!(this.#instance instanceof WebAssembly.Instance)) {
      throw new Error("instance must be an instance of WebAssembly.Instance");
    }

    // cache text encoder and decoder
    this.#textEncoder = new TextEncoder();
    this.#textDecoder = new TextDecoder();

    // initialize internal client state
    this.#instance.exports.initialize();
  }

  #allocateBytes(size) {
    if (typeof(size) != 'number' || !Number.isInteger(size) || size <= 0) {
      throw new Error("size must be a positive integer");
    }

    const exports = this.#instance.exports;
    return new PackedSlice(exports.memory, exports.allocateBytes(size));
  }

  #freeBytes(slice) {
    if (!(slice instanceof PackedSlice)) {
      throw new Error("slice must be an instance of PackedSlice");
    }

    this.#instance.exports.freeBytes(slice.value);
    slice.invalidate();
  }

  allocateDataBuffer(dataBuffer) {
    if (!(dataBuffer instanceof DataBuffer)) {
      throw new Error("dataBuffer must be a DataBuffer instance");
    }

    if (dataBuffer.isPackedSlice) {
      throw new Error("dataBuffer is already referencing allocated data");
    }

    const slice = this.#allocateBytes(dataBuffer.byteLength);
    const arrayBuffer = dataBuffer.exchangeWithPackedSlice(slice);
  }

  freeDataBuffer(dataBuffer) {
    if (!(dataBuffer instanceof DataBuffer)) {
      throw new Error("dataBuffer must be a DataBuffer instance");
    }

    if (!dataBuffer.isPackedSlice) {
      throw new Error("dataBuffer is not referencing allocated data");
    }

    // TODO: validate dataBuffer.#packedSlice.memory == this.#instance.memory

    const arrayBuffer = new ArrayBuffer(dataBuffer.byteLength);
    const slice = dataBuffer.exchangeWithArrayBuffer(arrayBuffer);
    this.#freeBytes(slice);
  }

  invoke(input) {
    console.debug("application invoke input:", input);

    // XXX: this should be encapsulated in a movable JSON object type?
    var inputData = this.#textEncoder.encode(JSON.stringify(input));
    var inputBuffer = new DataBuffer(Uint8Array, inputData.buffer.transfer());
    this.allocateDataBuffer(inputBuffer);

    // invoke the client
    const exports = this.#instance.exports;
    const outputSliceValue = exports.invoke(inputBuffer.packedSlice.value);
    const outputBuffer = new DataBuffer(Uint8Array, new PackedSlice(exports.memory, outputSliceValue));

    // XXX: this should be encapsulated in a movable JSON object type?
    var output = JSON.parse(this.#textDecoder.decode(outputBuffer.data));
    console.debug("application invoke output:", output);

    // free request and response memory in the client
    this.freeDataBuffer(inputBuffer);
    this.freeDataBuffer(outputBuffer);

    // handle errors by throwing
    if (Object.hasOwn(output, "error")) {
      throw new Error(`application invoke error: ${output.error.id}`);
    }

    // TODO: clean up complete request tasks
    if (Object.hasOwn(output, "httpResponse")) {
      console.log("TODO: clean up request tasks");
    }

    return output;
  }

  getTask(requestId, taskId) {
    console.debug(`application getTask input: ${requestId}, ${taskId}`);

    // invoke the client
    const exports = this.#instance.exports;
    const outputSliceValue = exports.getTask(requestId, taskId);
    const outputBuffer = new DataBuffer(Uint8Array, new PackedSlice(exports.memory, outputSliceValue));

    // XXX: this should be encapsulated in a movable JSON object type?
    var output = JSON.parse(this.#textDecoder.decode(outputBuffer.data));
    console.debug(`application getTask output:`, output);

    // free request and response memory in the client
    this.freeDataBuffer(outputBuffer);

    // handle client errors by throwing
    if (Object.hasOwn(output, "error")) {
      throw new Error(`application getTask error: ${output.error.id}`);
    }

    return output;
  }

  completeTask(requestId, taskId, result) {
    console.debug(`application completeTask input: ${requestId}, ${taskId}:`, result);

    // XXX: this should be encapsulated in a movable JSON object type?
    var resultData = this.#textEncoder.encode(JSON.stringify(result));
    var resultBuffer = new DataBuffer(Uint8Array, resultData.buffer.transfer());
    this.allocateDataBuffer(resultBuffer);

    // invoke the client
    const exports = this.#instance.exports;
    const outputSliceValue = exports.completeTask(requestId, taskId, resultBuffer.packedSlice.value);
    const outputBuffer = new DataBuffer(Uint8Array, new PackedSlice(exports.memory, outputSliceValue));

    // XXX: this should be encapsulated in a movable JSON object type?
    var output = JSON.parse(this.#textDecoder.decode(outputBuffer.data));
    console.debug("application completeTask output:", output);

    // free request and response memory in the client
    this.freeDataBuffer(resultBuffer);
    this.freeDataBuffer(outputBuffer);

    // handle client errors by throwing
    if (Object.hasOwn(output, "error")) {
      throw new Error(`application completeTask error: ${output.error.id}`);
    }

    return output;
  }
}

export class Loader {
  #sourceUrl;
  #importObject;
  #compileOptions;
  #application;
  #applicationResolve;
  #applicationReject;

  constructor(sourceUrl, importObject, compileOptions) {
    this.#sourceUrl = sourceUrl; // URL()
    this.#importObject = Object.assign({}, importObject); // Object()
    this.#compileOptions = Object.assign({}, compileOptions); // Object()

    if (!(this.#sourceUrl instanceof URL)) {
      throw new Error("sourceUrl must be an instance of URL");
    }

    this.#application = new Promise((resolve, reject) => {
      this.#applicationResolve = resolve;
      this.#applicationReject = reject;
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

  get application() {
    return this.#application;
  }

  async load() {
    try {
      const result = await WebAssembly.instantiateStreaming(
        fetch(this.#sourceUrl.toString()),
        this.#importObject,
        this.#compileOptions
      );

      const application = new Application(result.instance);
      this.#applicationResolve(application);
      return application;
    }
    catch (error) {
      this.#applicationReject(error);
      throw error;
    }
  }
}

export default {
  PackedSlice: PackedSlice,
  DataBuffer: DataBuffer,
  Application: Application,
  Loader: Loader,
};
