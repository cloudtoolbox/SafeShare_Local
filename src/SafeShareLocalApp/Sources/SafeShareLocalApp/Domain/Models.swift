import Foundation

enum ProfileCode: String, CaseIterable, Identifiable, Codable {
    case medical
    case studentFamily = "student_family"
    case researchSocialServices = "research_social_services"
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .medical: return "Medical"
        case .studentFamily: return "Student & Family"
        case .researchSocialServices: return "Research / Social Services"
        case .custom: return "Custom"
        }
    }
}

enum RedactionLevel: String, CaseIterable, Identifiable, Codable {
    case basic
    case medicalSafe = "medical_safe"
    case familyShare = "family_share"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .basic: return "Basic"
        case .medicalSafe: return "Medical Safe"
        case .familyShare: return "Family Share"
        }
    }
}

enum SourceKind: String {
    case pdf
    case image
    case text
}

enum DocumentMaterial: String, CaseIterable, Identifiable, Codable {
    case pdf
    case csv

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pdf: return "PDF"
        case .csv: return "CSV"
        }
    }
}

enum CSVMaskStrategy: String, CaseIterable, Identifiable, Codable {
    case stableHash = "stable_hash"
    case guid

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .stableHash: return "Stable Hash"
        case .guid: return "GUID"
        }
    }
}

enum CSVColumnPIIType: String, CaseIterable, Identifiable, Codable {
    case nonPII = "non_pii"
    case name
    case dateTime = "date_time"
    case phone
    case email
    case address
    case identifier
    case freeText = "free_text"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .nonPII: return "Non-PII"
        case .name: return "Name"
        case .dateTime: return "Date/Time Shift"
        case .phone: return "Phone"
        case .email: return "Email"
        case .address: return "Address"
        case .identifier: return "Identifier"
        case .freeText: return "Free Text"
        }
    }

    var tokenPrefix: String {
        switch self {
        case .nonPII: return "VALUE"
        case .name: return "NAME"
        case .dateTime: return "DATE"
        case .phone: return "PHONE"
        case .email: return "EMAIL"
        case .address: return "ADDRESS"
        case .identifier: return "ID"
        case .freeText: return "TEXT"
        }
    }
}

struct CSVColumnReview: Identifiable, Hashable {
    var id: Int { index }
    let index: Int
    let header: String
    var piiType: CSVColumnPIIType
    var confidence: Double
    var source: String
}

enum DecisionType: String, CaseIterable, Identifiable {
    case hide
    case keep
    case editToken = "edit_token"

    var id: String { rawValue }
}

enum DetectionSource: String {
    case rule
    case model
    case hybrid
    case user
}

struct AppProfile: Identifiable {
    let id: String
    let code: ProfileCode
    let displayName: String
    let description: String?
}

struct ProfileCategoryRule: Identifiable {
    let id: String
    let profileCode: ProfileCode
    let categoryCode: String
    var enabled: Bool
    var replacementToken: String
    let priority: Int
}

struct CustomPattern: Identifiable {
    let id: String
    let profileId: String
    let patternType: String
    var patternText: String
    var replacementToken: String
    var isCaseSensitive: Bool
    var enabled: Bool
    var notes: String?
}

struct IngestedDocument: Identifiable {
    let id: String
    let originalName: String
    let sourceKind: SourceKind
    let localPath: String
    let text: String
    let pageCount: Int
    let ocrLowConfidencePages: [Int]
    let pageTextMaps: [DocumentPageTextMap]
    let createdAt: Date
}

struct DocumentPageTextMap: Identifiable {
    var id: Int { pageIndex }
    let pageIndex: Int
    let pageText: String
    let globalStartOffset: Int
    let globalEndOffset: Int
}

struct RedactionEntity: Identifiable, Hashable {
    let id: String
    let categoryCode: String
    let rawValue: String
    let replacementToken: String
    let confidence: Double
    let source: DetectionSource
    let startOffset: Int
    let endOffset: Int
    var decision: DecisionType
    var editedToken: String?

    var effectiveToken: String {
        if decision == .editToken {
            return editedToken?.isEmpty == false ? editedToken! : replacementToken
        }
        return replacementToken
    }
}

struct RedactionJobResult {
    let jobId: String
    let document: IngestedDocument
    let entities: [RedactionEntity]
}

struct ExportArtifacts {
    let redactedTextPath: String
    let redactedPDFPath: String?
    let summarySafePath: String
    let clipboardSafeText: String
    let secondScanWarnings: [String]
}

struct CSVRedactionResult {
    let originalText: String
    let redactedText: String
    let maskedColumnCount: Int
    let maskedCellCount: Int
    let maskedHeaders: [String]
}

struct PromptTemplate {
    let profile: ProfileCode
    let content: String
}
