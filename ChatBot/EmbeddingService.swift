//
//  EmbeddingService.swift
//  ChatBot
//
//  On-device semantic embedding using Apple's NLContextualEmbedding (BERT).
//  Provides 512-dim context-aware vectors for chunks and queries, enabling
//  cosine-similarity retrieval instead of keyword matching.
//
//  Uses Apple's Accelerate framework (vDSP) for hardware-accelerated
//  vector operations: dot product, magnitude, cosine similarity, and
//  batch scoring against a Float32 embedding matrix.
//
//  Performance notes:
//  - Embeddings are L2-normalized at creation time so cosine similarity
//    reduces to a single dot product (no norm computation at query time).
//  - The EmbeddingMatrix stores Float32 for 2× memory reduction and
//    2× SIMD throughput (4 floats per NEON register vs 2 doubles).
//  - Batch scoring uses vDSP_mmul (Float32 matrix multiply) for the
//    hot path, processing all chunks in a single Accelerate call.
//

import Foundation
import Accelerate
@preconcurrency import NaturalLanguage

/// Singleton wrapper around `NLContextualEmbedding` for computing
/// on-device semantic embeddings. Used by both the knowledge-base
/// and memory stores for vector-based retrieval.
///
/// Marked `nonisolated` so embedding computation can run on background threads
/// without blocking the main actor.
nonisolated final class EmbeddingService: @unchecked Sendable {

    static let shared = EmbeddingService()

    /// The underlying contextual embedding model.
    private let embedding: NLContextualEmbedding?

    /// Whether the model assets are available on this device.
    private(set) var isAvailable: Bool = false

    /// The model identifier string — stored alongside vectors so we can
    /// detect when a re-embed is needed after an OS model update.
    var modelIdentifier: String {
        embedding?.modelIdentifier ?? ""
    }

    /// The dimensionality of the embedding vectors (typically 512).
    var dimension: Int {
        embedding.map { Int($0.dimension) } ?? 0
    }

    private init() {
        // Prefer English; falls back to the device's primary language
        if let emb = NLContextualEmbedding(language: .english) {
            self.embedding = emb
            self.isAvailable = emb.hasAvailableAssets
            if isAvailable {
                try? emb.load()
            }
        } else {
            self.embedding = nil
        }
    }

    // MARK: - Asset Management

    /// Request download of embedding model assets if not already present.
    /// The OS manages the download in the background (~100 MB, one-time).
    func requestAssetsIfNeeded(completion: ((Bool) -> Void)? = nil) {
        guard let embedding, !isAvailable else {
            completion?(isAvailable)
            return
        }
        embedding.requestAssets { [weak self] result, _ in
            let success = (result == .available)
            if success {
                try? embedding.load()
            }
            self?.isAvailable = success
            completion?(success)
        }
    }

    // MARK: - Embedding

    /// Compute a single embedding vector for the given text by mean-pooling
    /// the per-token vectors produced by the contextual model, then L2-normalizing.
    /// Uses vDSP for vectorized accumulation, scaling, and normalization.
    ///
    /// The returned vector is **unit-length** (L2 norm = 1), so cosine similarity
    /// between two normalized vectors is simply their dot product.
    ///
    /// Returns `nil` if the model is unavailable or the text cannot be embedded.
    func embed(_ text: String) -> [Double]? {
        guard let embedding, isAvailable else { return nil }

        guard let result = try? embedding.embeddingResult(for: text, language: nil) else {
            return nil
        }

        let dim = Int(embedding.dimension)
        var sum = [Double](repeating: 0.0, count: dim)
        var tokenCount = 0

        result.enumerateTokenVectors(in: text.startIndex ..< text.endIndex) { vector, _ in
            // vDSP vectorized addition: sum += vector
            let count = min(vector.count, dim)
            vDSP_vaddD(sum, 1, vector, 1, &sum, 1, vDSP_Length(count))
            tokenCount += 1
            return true // continue
        }

        guard tokenCount > 0 else { return nil }

        // vDSP vectorized scalar division: sum /= tokenCount (mean pooling)
        var scale = 1.0 / Double(tokenCount)
        vDSP_vsmulD(sum, 1, &scale, &sum, 1, vDSP_Length(dim))

        // L2 normalize to unit length so cosine similarity = dot product
        var norm = 0.0
        vDSP_dotprD(sum, 1, sum, 1, &norm, vDSP_Length(dim))
        norm = sqrt(norm)
        guard norm > 0 else { return nil }
        var invNorm = 1.0 / norm
        vDSP_vsmulD(sum, 1, &invNorm, &sum, 1, vDSP_Length(dim))

        return sum
    }

    // MARK: - Normalization Utilities

    /// L2-normalize a vector in-place. Returns false if the vector has zero magnitude.
    static func l2Normalize(_ v: inout [Double]) -> Bool {
        var norm = 0.0
        vDSP_dotprD(v, 1, v, 1, &norm, vDSP_Length(v.count))
        norm = sqrt(norm)
        guard norm > 0 else { return false }
        var invNorm = 1.0 / norm
        vDSP_vsmulD(v, 1, &invNorm, &v, 1, vDSP_Length(v.count))
        return true
    }

    /// Check if a vector is approximately unit-length (L2 norm ≈ 1.0).
    static func isNormalized(_ v: [Double], tolerance: Double = 0.01) -> Bool {
        var norm = 0.0
        vDSP_dotprD(v, 1, v, 1, &norm, vDSP_Length(v.count))
        return abs(norm - 1.0) < tolerance
    }

    // MARK: - Similarity (Accelerate / vDSP)

    /// Cosine similarity between two equal-length vectors using vDSP.
    /// If both vectors are pre-normalized (unit length), this reduces to a dot product.
    /// Returns a value in [-1, 1] where 1 = identical direction.
    static func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }

        // Fast path: if both vectors are normalized, just dot product
        if isNormalized(a) && isNormalized(b) {
            var dot = 0.0
            vDSP_dotprD(a, 1, b, 1, &dot, vDSP_Length(a.count))
            return dot
        }

        // Full cosine similarity for unnormalized vectors
        var dot = 0.0
        vDSP_dotprD(a, 1, b, 1, &dot, vDSP_Length(a.count))

        var magA = 0.0
        vDSP_dotprD(a, 1, a, 1, &magA, vDSP_Length(a.count))

        var magB = 0.0
        vDSP_dotprD(b, 1, b, 1, &magB, vDSP_Length(b.count))

        let denom = sqrt(magA) * sqrt(magB)
        guard denom > 0 else { return 0 }
        return dot / denom
    }

    /// Pre-computed magnitude (L2 norm) of a vector.
    static func magnitude(_ v: [Double]) -> Double {
        var sumSq = 0.0
        vDSP_dotprD(v, 1, v, 1, &sumSq, vDSP_Length(v.count))
        return sqrt(sumSq)
    }

    // MARK: - Batch Similarity (Float32, Accelerate / vDSP)

    /// Compute cosine similarities between a normalized query vector and a
    /// pre-computed Float32 embedding matrix of normalized vectors.
    ///
    /// Since all vectors are pre-normalized (unit length), cosine similarity
    /// equals the dot product — no norm computation needed. This eliminates
    /// 3 of the 4 steps in the old pipeline.
    ///
    /// Uses Float32 for 2× memory reduction and 2× SIMD throughput
    /// (NEON processes 4 floats per register vs 2 doubles).
    ///
    /// - Parameters:
    ///   - query: The query embedding as Float32 (dimension D, unit-normalized).
    ///   - matrix: Flat row-major Float32 array of N unit-normalized embeddings.
    ///   - count: Number of embeddings (N).
    ///   - dimension: The embedding dimension D (e.g. 512).
    /// - Returns: Array of N similarity scores (dot products).
    static func batchDotProduct(
        query: [Float],
        matrix: [Float],
        count: Int,
        dimension: Int
    ) -> [Float] {
        guard count > 0, dimension > 0, matrix.count == count * dimension else { return [] }

        // Single matrix multiply: matrix(N×D) × query(D×1) = similarities(N×1)
        // This is the entire scoring operation — no norms, no division needed.
        var result = [Float](repeating: 0.0, count: count)
        vDSP_mmul(
            matrix, 1,            // A (count × dimension)
            query, 1,             // B (dimension × 1)
            &result, 1,           // C (count × 1)
            vDSP_Length(count),   // M rows of A
            vDSP_Length(1),       // N columns of B
            vDSP_Length(dimension) // P shared dimension
        )

        return result
    }

    // MARK: - Legacy Batch Similarity (Float64, for backward compatibility)

    /// Compute cosine similarities using Float64 — used by MemoryStore
    /// and other code paths that haven't migrated to the Float32 matrix.
    static func batchCosineSimilarity(
        query: [Double],
        matrix: [Double],
        norms: [Double],
        dimension: Int
    ) -> [Double] {
        let n = norms.count
        guard n > 0, dimension > 0, matrix.count == n * dimension else { return [] }

        var dots = [Double](repeating: 0.0, count: n)
        vDSP_mmulD(
            matrix, 1,
            query, 1,
            &dots, 1,
            vDSP_Length(n),
            vDSP_Length(1),
            vDSP_Length(dimension)
        )

        let queryNorm = magnitude(query)
        guard queryNorm > 0 else { return [Double](repeating: 0.0, count: n) }

        var denominators = [Double](repeating: 0.0, count: n)
        var qn = queryNorm
        vDSP_vsmulD(norms, 1, &qn, &denominators, 1, vDSP_Length(n))

        var similarities = [Double](repeating: 0.0, count: n)
        vDSP_vdivD(denominators, 1, dots, 1, &similarities, 1, vDSP_Length(n))

        for i in 0 ..< n where denominators[i] == 0 {
            similarities[i] = 0
        }

        return similarities
    }
}

// MARK: - Embedding Matrix (Float32, Pre-normalized)

/// A pre-computed, flat Float32 embedding matrix for fast batch similarity scoring.
///
/// All embeddings are **pre-normalized to unit length**, so cosine similarity
/// equals a dot product. Combined with Float32 storage, this gives:
/// - **2× memory reduction** vs Float64 (4 bytes vs 8 bytes per element)
/// - **2× SIMD throughput** (NEON processes 4 floats per register vs 2 doubles)
/// - **No norm computation** at query time (just a single matrix multiply)
///
/// Build once when chunks are loaded; invalidated when chunks change.
struct EmbeddingMatrix: Sendable {
    /// Flat row-major Float32 storage of unit-normalized embeddings.
    let data: [Float]
    /// The embedding dimension (typically 512).
    let dimension: Int
    /// Number of rows (embeddings) in the matrix.
    let rowCount: Int
    /// Mapping from matrix row index → (chunkCacheKey: UUID, chunkIndex: Int)
    /// so we can trace a scored row back to the original DocumentChunk.
    let rowMap: [(knowledgeBaseID: UUID, chunkIndex: Int)]

    /// Build a Float32 embedding matrix from the chunk cache.
    /// Converts Double→Float and re-normalizes to ensure unit length.
    /// Only includes chunks that have non-nil embeddings.
    static func build(from chunkCache: [UUID: [DocumentChunk]], dimension: Int) -> EmbeddingMatrix {
        var matrixData: [Float] = []
        var rowMap: [(UUID, Int)] = []

        let totalCapacity = chunkCache.values.reduce(0) { $0 + $1.count } * dimension
        matrixData.reserveCapacity(totalCapacity)

        for (kbID, chunks) in chunkCache {
            for (chunkIdx, chunk) in chunks.enumerated() {
                guard let emb = chunk.embedding, emb.count == dimension else { continue }

                // Convert Double → Float and normalize in one pass
                var floatVec = emb.map { Float($0) }
                var norm: Float = 0.0
                vDSP_dotpr(floatVec, 1, floatVec, 1, &norm, vDSP_Length(dimension))
                norm = sqrtf(norm)
                if norm > 0 {
                    var invNorm = 1.0 / norm
                    vDSP_vsmul(floatVec, 1, &invNorm, &floatVec, 1, vDSP_Length(dimension))
                }

                matrixData.append(contentsOf: floatVec)
                rowMap.append((kbID, chunkIdx))
            }
        }

        return EmbeddingMatrix(
            data: matrixData,
            dimension: dimension,
            rowCount: rowMap.count,
            rowMap: rowMap
        )
    }

    /// Convert a Double query vector to Float32 and normalize for scoring.
    static func prepareQuery(_ query: [Double], dimension: Int) -> [Float] {
        var floatQuery = query.map { Float($0) }
        var norm: Float = 0.0
        vDSP_dotpr(floatQuery, 1, floatQuery, 1, &norm, vDSP_Length(dimension))
        norm = sqrtf(norm)
        if norm > 0 {
            var invNorm = 1.0 / norm
            vDSP_vsmul(floatQuery, 1, &invNorm, &floatQuery, 1, vDSP_Length(dimension))
        }
        return floatQuery
    }
}
