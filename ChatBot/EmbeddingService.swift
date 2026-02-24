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
//  batch scoring against an embedding matrix.
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
    /// the per-token vectors produced by the contextual model.
    /// Uses vDSP for vectorized accumulation and scaling.
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

        // vDSP vectorized scalar division: sum /= tokenCount
        var scale = 1.0 / Double(tokenCount)
        vDSP_vsmulD(sum, 1, &scale, &sum, 1, vDSP_Length(dim))
        return sum
    }

    // MARK: - Similarity (Accelerate / vDSP)

    /// Cosine similarity between two equal-length vectors using vDSP.
    /// Returns a value in [-1, 1] where 1 = identical direction.
    static func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }

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

    /// Pre-computed magnitude (L2 norm) of a vector, cached to avoid recomputation.
    static func magnitude(_ v: [Double]) -> Double {
        var sumSq = 0.0
        vDSP_dotprD(v, 1, v, 1, &sumSq, vDSP_Length(v.count))
        return sqrt(sumSq)
    }

    // MARK: - Batch Similarity (Accelerate / vDSP)

    /// Compute cosine similarities between a query vector and a pre-computed
    /// embedding matrix in a single vectorized pass.
    ///
    /// - Parameters:
    ///   - query: The query embedding vector (dimension D).
    ///   - matrix: A flat row-major array of N embeddings, each of dimension D
    ///             (total length = N × D). Use `EmbeddingMatrix` to build this.
    ///   - norms: Pre-computed L2 norms for each of the N embeddings.
    ///   - dimension: The embedding dimension D (e.g. 512).
    /// - Returns: Array of N cosine similarity scores.
    static func batchCosineSimilarity(
        query: [Double],
        matrix: [Double],
        norms: [Double],
        dimension: Int
    ) -> [Double] {
        let n = norms.count
        guard n > 0, dimension > 0, matrix.count == n * dimension else { return [] }

        // Step 1: Compute dot products — query · each row
        // Treat as matrix(N×D) × query(D×1) = result(N×1)
        // vDSP_mmulD computes C = A × B where A is (M×P), B is (P×N), C is (M×N)
        // Here: A = matrix (n×dimension), B = query (dimension×1), C = dots (n×1)
        var dots = [Double](repeating: 0.0, count: n)
        vDSP_mmulD(
            matrix, 1,           // A (n × dimension)
            query, 1,            // B (dimension × 1)
            &dots, 1,            // C (n × 1)
            vDSP_Length(n),      // M rows of A
            vDSP_Length(1),      // N columns of B
            vDSP_Length(dimension) // P shared dimension
        )

        // Step 2: Compute query norm once
        let queryNorm = magnitude(query)
        guard queryNorm > 0 else { return [Double](repeating: 0.0, count: n) }

        // Step 3: Compute denominators = norms[i] * queryNorm
        var denominators = [Double](repeating: 0.0, count: n)
        var qn = queryNorm
        vDSP_vsmulD(norms, 1, &qn, &denominators, 1, vDSP_Length(n))

        // Step 4: Divide dots by denominators element-wise
        var similarities = [Double](repeating: 0.0, count: n)
        vDSP_vdivD(denominators, 1, dots, 1, &similarities, 1, vDSP_Length(n))

        // Replace NaN/inf with 0 (from zero-norm vectors)
        for i in 0 ..< n where denominators[i] == 0 {
            similarities[i] = 0
        }

        return similarities
    }
}

// MARK: - Embedding Matrix

/// A pre-computed, flat embedding matrix for fast batch similarity scoring.
/// Stores all embeddings as a contiguous row-major `[Double]` array alongside
/// pre-computed L2 norms, enabling single-call vDSP/BLAS batch operations.
///
/// Build once when chunks are loaded; invalidate when chunks change.
struct EmbeddingMatrix: Sendable {
    /// Flat row-major storage: [row0_d0, row0_d1, ..., row0_dD, row1_d0, ...]
    let data: [Double]
    /// Pre-computed L2 norms for each row (length = rowCount).
    let norms: [Double]
    /// The embedding dimension (typically 512).
    let dimension: Int
    /// Number of rows (embeddings) in the matrix.
    let rowCount: Int
    /// Mapping from matrix row index → (chunkCacheKey: UUID, chunkIndex: Int)
    /// so we can trace a scored row back to the original DocumentChunk.
    let rowMap: [(knowledgeBaseID: UUID, chunkIndex: Int)]

    /// Build an embedding matrix from the chunk cache.
    /// Only includes chunks that have non-nil embeddings.
    static func build(from chunkCache: [UUID: [DocumentChunk]], dimension: Int) -> EmbeddingMatrix {
        var matrixData: [Double] = []
        var norms: [Double] = []
        var rowMap: [(UUID, Int)] = []

        matrixData.reserveCapacity(chunkCache.values.reduce(0) { $0 + $1.count } * dimension)

        for (kbID, chunks) in chunkCache {
            for (chunkIdx, chunk) in chunks.enumerated() {
                guard let emb = chunk.embedding, emb.count == dimension else { continue }
                matrixData.append(contentsOf: emb)
                norms.append(EmbeddingService.magnitude(emb))
                rowMap.append((kbID, chunkIdx))
            }
        }

        return EmbeddingMatrix(
            data: matrixData,
            norms: norms,
            dimension: dimension,
            rowCount: rowMap.count,
            rowMap: rowMap
        )
    }
}
