///
/// Copyright (c) 2016 Dropbox, Inc. All rights reserved.
///
/// Auto-generated by Stone, do not modify.
///

import Foundation

import Alamofire

open class DropboxBase {
    /// Routes within the account namespace. See AccountRoutes for details.
    open var account: AccountRoutes!
    /// Routes within the auth namespace. See AuthRoutes for details.
    open var auth: AuthRoutes!
    /// Routes within the check namespace. See CheckRoutes for details.
    open var check: CheckRoutes!
    /// Routes within the contacts namespace. See ContactsRoutes for details.
    open var contacts: ContactsRoutes!
    /// Routes within the file_properties namespace. See FilePropertiesRoutes for details.
    open var file_properties: FilePropertiesRoutes!
    /// Routes within the file_requests namespace. See FileRequestsRoutes for details.
    open var file_requests: FileRequestsRoutes!
    /// Routes within the files namespace. See FilesRoutes for details.
    open var files: FilesRoutes!
    /// Routes within the openid namespace. See OpenidRoutes for details.
    open var openid: OpenidRoutes!
    /// Routes within the paper namespace. See PaperRoutes for details.
    open var paper: PaperRoutes!
    /// Routes within the sharing namespace. See SharingRoutes for details.
    open var sharing: SharingRoutes!
    /// Routes within the team_log namespace. See TeamLogRoutes for details.
    open var team_log: TeamLogRoutes!
    /// Routes within the users namespace. See UsersRoutes for details.
    open var users: UsersRoutes!

    public init(client: DropboxTransportClient) {
        self.account = AccountRoutes(client: client)
        self.auth = AuthRoutes(client: client)
        self.check = CheckRoutes(client: client)
        self.contacts = ContactsRoutes(client: client)
        self.file_properties = FilePropertiesRoutes(client: client)
        self.file_requests = FileRequestsRoutes(client: client)
        self.files = FilesRoutes(client: client)
        self.openid = OpenidRoutes(client: client)
        self.paper = PaperRoutes(client: client)
        self.sharing = SharingRoutes(client: client)
        self.team_log = TeamLogRoutes(client: client)
        self.users = UsersRoutes(client: client)
    }
}
