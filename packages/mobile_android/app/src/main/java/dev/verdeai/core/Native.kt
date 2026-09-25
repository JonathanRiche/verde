package dev.verdeai.core

object Native {
    init {
        System.loadLibrary("verde_client")
    }

    @JvmStatic external fun hostNew(json: ByteArray, status: IntArray): Long
    @JvmStatic external fun hostFree(host: Long)
    @JvmStatic external fun hostHandle(host: Long, json: ByteArray, status: IntArray): ByteArray?
    @JvmStatic external fun hostQuery(host: Long, selector: ByteArray, status: IntArray): ByteArray?
    @JvmStatic external fun version(): String
}
