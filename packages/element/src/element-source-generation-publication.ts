/** Publishes a generation number only after its physical owner was constructed. */
export class ElementSourceGenerationPublication {
  #value = 0;

  public get value(): number { return this.#value; }

  public construct<Owner>(generation: number, create: () => Owner): Owner {
    if (!Number.isSafeInteger(generation) || generation < 1) {
      throw new RangeError("source generation is invalid");
    }
    const owner = create();
    this.#value = generation;
    return owner;
  }
}
