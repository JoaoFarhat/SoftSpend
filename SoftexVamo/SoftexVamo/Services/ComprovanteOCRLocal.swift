//
//  ComprovanteOCRLocal.swift
//  SoftexVamo
//

import Foundation
import UIKit
import Vision

enum ComprovanteOCRLocal {

    static func extrair(de image: UIImage) async -> GastoLocalExtraido {
        guard let linhas = await reconhecerTexto(em: image) else {
            return GastoLocalExtraido()
        }

        return InterpretadorComprovante.interpretar(linhas: linhas)
    }

    private static func reconhecerTexto(em image: UIImage) async -> [String]? {
        guard let cgImage = image.cgImage else { return nil }

        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let observacoes = request.results as? [VNRecognizedTextObservation] ?? []

                let linhas = observacoes
                    .sorted { $0.boundingBox.midY > $1.boundingBox.midY }
                    .compactMap { $0.topCandidates(1).first?.string }

                continuation.resume(returning: linhas)
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["pt-BR", "en-US"]

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }

}
