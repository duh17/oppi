import { createNodePhotonImages } from "@earendil-works/pi-durable/images/node";
import { createCodingTools, type ImageProcessor } from "@earendil-works/pi-durable/tools";

/**
 * Longest edge of an image `read` gives the model. Without a processor, `read` sent every image
 * up to 2000x2000 at its full file size and refused larger ones; a session that read a few dozen
 * photos carried tens of MB of base64 in every request. 1568 px is the standard vision tier's
 * native size; high-resolution models (Claude 4.7 and later) could take up to 2576 px, at
 * roughly 1.5x the tokens for a 1920x1080 image.
 */
export const READ_IMAGE_MAX_EDGE = 1568;

let photon: Promise<ImageProcessor> | undefined;

/**
 * Photon, loaded on the first image read and run in a worker thread that exits when idle. It
 * scales an image down to `READ_IMAGE_MAX_EDGE` (and the model's own limits) and re-encodes it,
 * JPEG at quality 80 first; an image already within them is sent as it is.
 */
export const readImages: ImageProcessor = {
  async prepare(bytes, mimeType, limits) {
    photon ??= createNodePhotonImages();
    // The worker transfers the backing store of what it gets. A `Buffer` view (the sandbox's
    // reader slices one) would detach the reader's whole file, and a pooled small Buffer cannot
    // be transferred at all, so it gets a copy of its own.
    return (await photon).prepare(new Uint8Array(bytes), mimeType, {
      ...limits,
      maxWidth: Math.min(limits.maxWidth, READ_IMAGE_MAX_EDGE),
      maxHeight: Math.min(limits.maxHeight, READ_IMAGE_MAX_EDGE),
    });
  },
};

/** pi-durable's `read`, `write`, `edit`, and `bash`, with images shrunk on read. */
export const CodingTools = createCodingTools({ images: readImages });
