package dev.verdeai.core

object Native {
    init {
        System.loadLibrary("verde_client")
    }

    @JvmStatic external fun version(): String
}
