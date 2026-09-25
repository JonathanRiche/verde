package dev.verdeai.core

object Native {
    init {
        System.loadLibrary("verde_client")
    }

    @JvmStatic external fun hostNew(json: ByteArray, status: IntArray): Long
    @JvmStatic external fun hostFree(host: Long)
    @JvmStatic external fun hostHandle(host: Long, json: ByteArray, status: IntArray): ByteArray?
    @JvmStatic external fun hostQuery(host: Long, selector: ByteArray, status: IntArray): ByteArray?
    @JvmStatic external fun termNew(json: ByteArray, status: IntArray): Long
    @JvmStatic external fun termFree(term: Long)
    @JvmStatic external fun termWrite(term: Long, bytes: ByteArray): Int
    @JvmStatic external fun termResize(term: Long, cols: Int, rows: Int): Int
    @JvmStatic external fun termScroll(term: Long, deltaRows: Int): Int
    @JvmStatic external fun termSnapshot(term: Long, status: IntArray): ByteArray?
    @JvmStatic external fun version(): String
    @JvmStatic external fun pushOpen(json: ByteArray, status: IntArray): ByteArray?
}
