package com.anime.konata

import android.database.Cursor
import android.database.MatrixCursor
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract.Document
import android.provider.DocumentsContract.Root
import android.provider.DocumentsProvider
import android.webkit.MimeTypeMap
import java.io.File
import java.io.FileNotFoundException

/** Read-only SAF access to artwork only. Never exposes the library, credentials,
 * cache index, temporary downloads, or arbitrary paths under app storage. */
class ArtworkDocumentsProvider : DocumentsProvider() {
    private val root get() = File(requireNotNull(context).filesDir, "artwork").canonicalFile
    private val documentColumns = arrayOf(Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME,
        Document.COLUMN_MIME_TYPE, Document.COLUMN_FLAGS, Document.COLUMN_SIZE, Document.COLUMN_LAST_MODIFIED)
    override fun onCreate() = true

    private fun visible(file: File): Boolean = file.isDirectory ||
        file.name.matches(Regex("(?:original_|crop_)?[a-f0-9]{64}\\.(?:png|jpg|webp|gif)")) ||
        file.name.matches(Regex("cache_[a-f0-9]{64}"))

    private fun resolve(id: String): File {
        if (id == "artwork") return root
        if (!id.startsWith("artwork/")) throw FileNotFoundException()
        val file = File(root, id.removePrefix("artwork/")).canonicalFile
        if (!file.path.startsWith(root.path + File.separator) || !file.exists() || !visible(file))
            throw FileNotFoundException()
        return file
    }

    private fun id(file: File) = if (file == root) "artwork" else "artwork/" + file.relativeTo(root).invariantSeparatorsPath
    private fun add(cursor: MatrixCursor, file: File) {
        val mime = if (file.isDirectory) Document.MIME_TYPE_DIR
            else MimeTypeMap.getSingleton().getMimeTypeFromExtension(file.extension) ?: "image/*"
        val values = mapOf<String, Any?>(Document.COLUMN_DOCUMENT_ID to id(file),
            Document.COLUMN_DISPLAY_NAME to if (file == root) "Konata images" else file.name,
            Document.COLUMN_MIME_TYPE to mime, Document.COLUMN_FLAGS to 0,
            Document.COLUMN_SIZE to if (file.isDirectory) null else file.length(),
            Document.COLUMN_LAST_MODIFIED to file.lastModified())
        cursor.addRow(cursor.columnNames.map { values[it] }.toTypedArray())
    }

    override fun queryRoots(projection: Array<out String>?): Cursor {
        val columns = projection ?: arrayOf(Root.COLUMN_ROOT_ID, Root.COLUMN_DOCUMENT_ID,
            Root.COLUMN_TITLE, Root.COLUMN_FLAGS, Root.COLUMN_MIME_TYPES, Root.COLUMN_ICON)
        val cursor = MatrixCursor(columns)
        root.mkdirs()
        val values = mapOf<String, Any>(Root.COLUMN_ROOT_ID to "artwork", Root.COLUMN_DOCUMENT_ID to "artwork",
            Root.COLUMN_TITLE to "Konata images", Root.COLUMN_FLAGS to Root.FLAG_LOCAL_ONLY,
            Root.COLUMN_MIME_TYPES to "image/*", Root.COLUMN_ICON to requireNotNull(context).applicationInfo.icon)
        cursor.addRow(columns.map { values[it] }.toTypedArray())
        return cursor
    }

    override fun queryDocument(documentId: String, projection: Array<out String>?): Cursor =
        MatrixCursor(projection ?: documentColumns).also { add(it, resolve(documentId)) }

    override fun queryChildDocuments(parentDocumentId: String, projection: Array<out String>?, sortOrder: String?): Cursor {
        val cursor = MatrixCursor(projection ?: documentColumns)
        resolve(parentDocumentId).listFiles()?.filter { visible(it) && it.canonicalFile == it.absoluteFile }
            ?.sortedBy { it.name }?.forEach { add(cursor, it) }
        return cursor
    }

    override fun openDocument(documentId: String, mode: String, signal: CancellationSignal?): ParcelFileDescriptor {
        if (mode != "r") throw FileNotFoundException("Read only")
        val file = resolve(documentId)
        if (!file.isFile) throw FileNotFoundException()
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun isChildDocument(parentDocumentId: String, documentId: String): Boolean =
        resolve(documentId).path.startsWith(resolve(parentDocumentId).path + File.separator)
}
