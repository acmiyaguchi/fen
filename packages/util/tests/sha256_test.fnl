(local sha256 (require :fen.util.sha256))

(describe "util.sha256"
  (fn []
    (it "hashes the empty string (FIPS 180-4 vector)"
      (fn []
        (assert.are.equal
          "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
          (sha256.hex-digest ""))))

    (it "hashes 'abc' (FIPS 180-4 vector)"
      (fn []
        (assert.are.equal
          "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
          (sha256.hex-digest "abc"))))

    (it "hashes a two-block input (FIPS 180-4 vector)"
      (fn []
        ;; 56-byte input forces a second block (after the 0x80 + length suffix
        ;; the message no longer fits in one 64-byte block).
        (assert.are.equal
          "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
          (sha256.hex-digest
            "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"))))

    (it "digest returns 32 raw bytes"
      (fn []
        (let [raw (sha256.digest "abc")]
          (assert.are.equal 32 (length raw)))))

    (it "different inputs produce different digests"
      (fn []
        (assert.is_not.equal (sha256.hex-digest "a") (sha256.hex-digest "b"))))))
