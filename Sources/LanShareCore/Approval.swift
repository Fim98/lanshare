import Foundation

public protocol UploadApprovalProviding: AnyObject {
    func requestApproval(clientIP: String, payload: UploadInitPayload) async -> Bool
}
