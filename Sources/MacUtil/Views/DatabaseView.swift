import SwiftUI
import AppKit
import DatabaseModule

// DB-09: SQL editor + bảng kết quả phân trang.

struct DatabaseView: View {
    @ObservedObject var state: DatabaseState
    @State private var expanded: Set<UUID> = []
    @State private var expandedCats: Set<String> = []
    @State private var selectedRow: Int?
    /// Object đang xem source (để hiện nút Run… trên editor như SQL Developer).
    @State private var loadedObject: DBSchemaObject?

    var body: some View {
        HSplitView {
            connectionsSidebar
                .frame(minWidth: 240, maxWidth: 320)
            mainPanel
        }
    }

    // MARK: - Connections sidebar (gộp connection + schema thành 1 cây)

    private var connectionsSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Connections").font(.headline).padding(.leading, 12)
                Spacer()
                Button { openAddProfileWindow() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .padding(.trailing, 10)
            }
            .padding(.vertical, 8)
            Divider()
            List {
                ForEach(state.profiles) { profile in
                    connectionNode(profile)
                }
            }
            .listStyle(.sidebar)
        }
    }

    private func connectionNode(_ p: ConnectionProfile) -> some View {
        let isConnected = state.selectedProfileID == p.id && state.isConnected
        return DisclosureGroup(isExpanded: Binding(
            get: { expanded.contains(p.id) },
            set: { open in
                if open {
                    expanded.insert(p.id)
                    if !(state.selectedProfileID == p.id && state.isConnected) {
                        state.connect(to: p)   // kết nối + tải schema khi bung
                    }
                } else {
                    expanded.remove(p.id)
                }
            }
        )) {
            schemaContent(for: p, isConnected: isConnected)
        } label: {
            connectionLabel(p, isConnected: isConnected)
        }
    }

    private func connectionLabel(_ p: ConnectionProfile, isConnected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: dbIcon(p.type)).foregroundStyle(dbColor(p.type))
            VStack(alignment: .leading, spacing: 1) {
                Text(p.name.isEmpty ? "\(p.host):\(p.port)" : p.name)
                    .font(.body.weight(.medium)).lineLimit(1)
                Text("\(p.type.rawValue) · \(p.host):\(p.port)")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Circle().fill(isConnected ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
        }
        // #4: context menu của CONNECTION chỉ gắn ở node connection.
        .contextMenu {
            if isConnected {
                Button("Ngắt kết nối") { state.disconnect(); expanded.remove(p.id) }
            } else {
                Button("Kết nối") { expanded.insert(p.id); state.connect(to: p) }
            }
            Divider()
            Button("Xóa", role: .destructive) {
                if let idx = state.profiles.firstIndex(where: { $0.id == p.id }) {
                    state.deleteProfile(at: IndexSet(integer: idx))
                }
            }
        }
    }

    /// Nội dung dưới mỗi connection: folder cố định + lazy-load object.
    @ViewBuilder
    private func schemaContent(for p: ConnectionProfile, isConnected: Bool) -> some View {
        if isConnected {
            ForEach(state.categories) { cat in
                categoryFolder(cat)
            }
        } else if state.isBusy && state.selectedProfileID == p.id {
            Label("Đang kết nối…", systemImage: "hourglass").font(.caption).foregroundStyle(.secondary)
        } else {
            Text("Bung để kết nối").font(.caption).foregroundStyle(.tertiary)
        }
    }

    /// Một folder loại (Tables, Packages…): bung lần đầu → lazy query object.
    private func categoryFolder(_ cat: SchemaCategory) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { expandedCats.contains(cat.id) },
            set: { open in
                if open { expandedCats.insert(cat.id); state.loadCategory(cat) }
                else { expandedCats.remove(cat.id) }
            }
        )) {
            if state.loadingCategories.contains(cat.id) {
                Label("Đang tải…", systemImage: "hourglass").font(.caption).foregroundStyle(.secondary)
            } else if let objs = state.objectsByCategory[cat.id] {
                if objs.isEmpty {
                    Text("(trống)").font(.caption).foregroundStyle(.tertiary)
                } else {
                    ForEach(objs) { obj in
                        HStack(spacing: 6) {
                            Image(systemName: schemaIcon(obj.type))
                                .foregroundStyle(schemaColor(obj.type)).frame(width: 14)
                            Text(obj.name).font(.callout).lineLimit(1)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { handleObjectTap(obj) }
                        .contextMenu { objectMenu(obj) }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill").foregroundStyle(schemaColor(cat.id))
                Text(cat.title).font(.callout)
                if let n = state.objectsByCategory[cat.id]?.count {
                    Text("(\(n))").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - Main panel (chỉ còn SQL editor + kết quả)

    private var mainPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            Divider()
            if state.isConnected {
                editorAndResults
            } else {
                emptyState
            }
            statusBar
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text("Database Client").font(.largeTitle.bold())
            Spacer()
            if state.isBusy { ProgressView().controlSize(.small) }
            if state.isConnected {
                HStack(spacing: 4) {
                    Text("Số dòng:").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $state.rowLimit) {
                        Text("100").tag(100)
                        Text("250").tag(250)
                        Text("500").tag(500)
                        Text("1000").tag(1000)
                        Text("5000").tag(5000)
                    }
                    .labelsHidden()
                    .frame(width: 90)
                }
                Button("Ngắt kết nối") { state.disconnect() }
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var editorAndResults: some View {
        VSplitView {
            sqlEditor
                .frame(minHeight: 160, idealHeight: 240, maxHeight: .infinity)
            resultTable
                .frame(minHeight: 160, maxHeight: .infinity)
        }
    }

    private var worksheetTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(state.worksheets) { ws in
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text").font(.caption2)
                        Text(ws.title).font(.callout)
                        if state.worksheets.count > 1 {
                            Button { state.closeWorksheet(ws.id) } label: {
                                Image(systemName: "xmark").font(.system(size: 8))
                            }.buttonStyle(.borderless)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(state.activeWorksheet == ws.id ? Color.accentColor.opacity(0.18) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                    .onTapGesture { state.switchWorksheet(ws.id) }
                }
                Button { state.addWorksheet() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).padding(.horizontal, 6)
            }
            .padding(.horizontal, 12).padding(.top, 8)
        }
    }

    private var sqlEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            worksheetTabs
            HStack {
                Label("SQL Editor", systemImage: "pencil.and.list.clipboard").font(.headline)
                Spacer()
                // Nút Run… cho object đang mở (package/proc/func) — mở dialog chọn/nhập tham số.
                if let obj = loadedObject {
                    Button("▶ Run…") { runLoadedObject() }
                        .buttonStyle(.borderedProminent).tint(.green)
                        .help("Chọn/nhập tham số rồi chạy \(obj.name) (như Run PL/SQL của SQL Developer)")
                    Button("Compile") { state.execute() }
                        .help("Biên dịch lại source trong editor (CREATE OR REPLACE)")
                        .disabled(state.queryText.isEmpty)
                }
                Button("▶ Run Query  ⌘↵") { state.runQuery() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Chạy SELECT, hiện kết quả dạng bảng (⌘ + Enter)")
                    .disabled(!state.isConnected || state.queryText.isEmpty)
                Button("Execute  ⌘⏎") { state.execute() }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .help("Compile source / chạy DDL-DML-PLSQL (⌘⇧ + Enter)")
                    .disabled(!state.isConnected || state.queryText.isEmpty)
            }
            .padding(.horizontal, 12).padding(.top, 10)

            SQLTextEditor(text: $state.queryText)
                .background(Color(nsColor: .textBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.quaternary, lineWidth: 1)
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var resultTable: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Label("Kết quả", systemImage: "tablecells").font(.headline)
                if state.isEditable {
                    Button { openRowEditor(insert: true) } label: { Label("Thêm", systemImage: "plus") }
                    Button { openRowEditor(insert: false) } label: { Label("Sửa", systemImage: "pencil") }
                        .disabled(selectedRow == nil)
                    Button(role: .destructive) { deleteSelectedRow() } label: { Label("Xóa", systemImage: "trash") }
                        .disabled(selectedRow == nil)
                }
                Spacer()
                if let r = state.queryResult {
                    Text("\(r.rows.count) dòng" + (r.rows.count >= state.rowLimit ? " (giới hạn \(state.rowLimit))" : ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            if let result = state.queryResult {
                if result.rows.isEmpty {
                    Text("Không có hàng nào.").foregroundStyle(.secondary).padding(12)
                    Spacer()
                } else {
                    ResultTableView(result: result,
                                    columns: state.visibleColumns,
                                    selectedRow: $selectedRow)
                }
            } else {
                Text("Chưa chạy query.").foregroundStyle(.tertiary).padding(12)
                Spacer()
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "cylinder.split.1x2").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("Chọn connection ở sidebar để bắt đầu.").foregroundStyle(.secondary)
            Button("Thêm connection mới") { openAddProfileWindow() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Window-based form (tránh sheet focus bug trên macOS)

    private func openAddProfileWindow() {
        let dbState = state
        presentInWindow(title: "Thêm connection", width: 500, height: 440) { dismiss in
            AddProfileSheet { profile, password in
                dbState.addProfile(profile, password: password)
                dismiss()
            } onCancel: { dismiss() }
        }
    }

    private func openConnectWindow(for profile: ConnectionProfile) {
        let dbState = state
        presentInWindow(
            title: "Kết nối \(profile.name.isEmpty ? profile.host : profile.name)",
            width: 360, height: 180
        ) { dismiss in
            ConnectPasswordSheet(profile: profile) { password in
                dbState.addProfile(profile, password: password)
                dbState.connect(to: profile)
                dismiss()
            } onCancel: { dismiss() }
        }
    }

    private var statusBar: some View {
        HStack {
            if !state.statusMessage.isEmpty {
                Text(state.statusMessage).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.bar)
    }

    // MARK: - #3: Row editor (thêm/sửa dòng)

    private func deleteSelectedRow() {
        guard let idx = selectedRow, let rows = state.queryResult?.rows, idx < rows.count,
              let rowid = (rows[idx][SingleTableEdit.rowidColumn] ?? nil) else { return }
        let rid = rowid
        presentInWindow(title: "Xóa dòng", width: 320, height: 140) { dismiss in
            VStack(alignment: .leading, spacing: 16) {
                Label("Xóa dòng này khỏi \(state.editableTable ?? "")?", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("ROWID: \(rid)").font(.caption.monospaced()).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Hủy") { dismiss() }
                    Button("Xóa", role: .destructive) { state.deleteRow(rowid: rid); selectedRow = nil; dismiss() }
                        .buttonStyle(.borderedProminent).tint(.red)
                }
            }.padding(20)
        }
    }

    /// #2: procedure/function top-level → popup nhập tham số.
    private func runProcedure(_ obj: DBSchemaObject) {
        let isFunction = obj.type.uppercased() == "FUNCTION"
        Task {
            let args = await state.fetchArguments(obj.name)
            presentParamSheet(callName: obj.name, isFunction: isFunction, args: args)
        }
    }

    /// #2: PACKAGE → chọn procedure trong package rồi nhập tham số (giống Run PL/SQL của SQL Developer).
    private func runPackage(_ obj: DBSchemaObject) {
        Task {
            let members = await state.fetchPackageMembers(obj.name)
            guard !members.isEmpty else {
                state.statusMessage = "Package \(obj.name) không có procedure/function public."
                return
            }
            presentInWindow(title: "Run — \(obj.name)", width: 380, height: 440) { dismiss in
                PackageMemberSheet(packageName: obj.name, members: members) { member in
                    dismiss()
                    runMember(pkg: obj.name, member: member)
                } onCancel: { dismiss() }
            }
        }
    }

    private func runMember(pkg: String, member: String) {
        Task {
            let args = await state.fetchArguments(member, package: pkg)
            let isFunction = args.contains { $0.id == 0 }
            presentParamSheet(callName: "\(pkg).\(member)", isFunction: isFunction, args: args)
        }
    }

    /// Mở popup nhập tham số IN; nếu không có IN thì chạy luôn.
    private func presentParamSheet(callName: String, isFunction: Bool, args: [ProcArg]) {
        let inArgs = args.filter { $0.id >= 1 && $0.isIn }
        if inArgs.isEmpty {
            state.runProcedureCall(name: callName, isFunction: isFunction, args: args, values: [:])
            return
        }
        presentInWindow(title: "Run \(callName)",
                        width: 480, height: min(640, CGFloat(inArgs.count) * 48 + 160)) { dismiss in
            ProcRunSheet(objectName: callName, isFunction: isFunction, inArgs: inArgs) { values in
                state.runProcedureCall(name: callName, isFunction: isFunction, args: args, values: values)
                dismiss()
            } onCancel: { dismiss() }
        }
    }

    private func openRowEditor(insert: Bool) {
        let cols = state.visibleColumns
        var initial: [String: String] = [:]
        var rowid: String? = nil
        if !insert, let idx = selectedRow, let rows = state.queryResult?.rows, idx < rows.count {
            let row = rows[idx]
            for c in cols { initial[c] = (row[c] ?? nil) ?? "" }
            rowid = (row[SingleTableEdit.rowidColumn] ?? nil)
        }
        let table = state.editableTable ?? ""
        presentInWindow(title: insert ? "Thêm dòng — \(table)" : "Sửa dòng — \(table)",
                        width: 460, height: min(620, CGFloat(cols.count) * 44 + 130)) { dismiss in
            RowEditorSheet(columns: cols, initial: initial, isInsert: insert) { values in
                if insert {
                    // Gửi tất cả cột (trống = NULL).
                    let v = Dictionary(uniqueKeysWithValues: cols.map { ($0, values[$0]?.isEmpty == false ? values[$0]! : nil) })
                    state.insertRow(values: v)
                } else if let rid = rowid {
                    // Chỉ gửi cột đã thay đổi (tránh đụng cột ngày/timestamp).
                    var changed: [String: String?] = [:]
                    for c in cols where (values[c] ?? "") != (initial[c] ?? "") {
                        changed[c] = values[c]?.isEmpty == false ? values[c]! : nil
                    }
                    if changed.isEmpty { dismiss(); return }
                    state.updateRow(rowid: rid, values: changed)
                }
                dismiss()
            } onCancel: { dismiss() }
        }
    }

    // MARK: - Helpers

    private func dbIcon(_ type: DatabaseType) -> String {
        switch type { case .mysql: "m.circle"; case .redis: "r.circle"; case .oracle: "o.circle" }
    }
    private func dbColor(_ type: DatabaseType) -> Color {
        switch type { case .mysql: .orange; case .redis: .red; case .oracle: .blue }
    }
    private func schemaIcon(_ type: String) -> String {
        switch type.uppercased() {
        case "TABLE":                       "tablecells"
        case "VIEW", "MATERIALIZED VIEW":    "eye"
        case "INDEX":                        "list.bullet.indent"
        case "PACKAGE", "PACKAGE BODY":      "shippingbox"
        case "PROCEDURE", "FUNCTION":        "gearshape"
        case "TRIGGER":                      "bolt"
        case "TYPE":                         "cube"
        case "SEQUENCE":                     "number"
        case "SYNONYM":                      "arrow.triangle.branch"
        case "DATABASE LINK":                "link"
        default:                             "doc"
        }
    }
    private func schemaColor(_ type: String) -> Color {
        switch type.uppercased() {
        case "TABLE":                   .blue
        case "VIEW", "MATERIALIZED VIEW": .purple
        case "INDEX":                   .teal
        case "PACKAGE", "PACKAGE BODY": .orange
        case "PROCEDURE", "FUNCTION":   .green
        case "TRIGGER":                 .pink
        case "TYPE":                    .indigo
        case "SEQUENCE":                .brown
        case "DATABASE LINK":           .cyan
        default:                        .gray
        }
    }

    private var isCodeObject: (DBSchemaObject) -> Bool {
        { ["PACKAGE", "PACKAGE BODY", "PROCEDURE", "FUNCTION", "TRIGGER", "TYPE", "TYPE BODY", "VIEW"]
            .contains($0.type.uppercased()) }
    }

    /// #2: code object → tải source vào editor; table → SELECT.
    private func handleObjectTap(_ obj: DBSchemaObject) {
        if isCodeObject(obj) {
            state.loadObjectSource(obj)
            // Object chạy được (package/proc/func) → bật nút Run… trên editor.
            let t = obj.type.uppercased()
            loadedObject = (t == "PACKAGE" || t == "PROCEDURE" || t == "FUNCTION") ? obj : nil
        } else {
            state.queryText = defaultQuery(for: obj)
            loadedObject = nil
        }
    }

    /// Dispatch Run theo loại object đang mở.
    private func runLoadedObject() {
        guard let obj = loadedObject else { return }
        if obj.type.uppercased() == "PACKAGE" { runPackage(obj) }
        else { runProcedure(obj) }
    }

    /// #4: menu chuột phải cho object (table/view/code).
    @ViewBuilder
    private func objectMenu(_ obj: DBSchemaObject) -> some View {
        let t = obj.type.uppercased()
        if t == "TABLE" || t == "VIEW" || t == "MATERIALIZED VIEW" {
            Button("Xem \(state.rowLimit) dòng đầu") { state.queryText = defaultQuery(for: obj); state.runQuery() }
            Button("Mở SQL SELECT") { state.queryText = defaultQuery(for: obj) }
            Button("Xem cấu trúc cột") {
                state.queryText = "SELECT * FROM ALL_TAB_COLUMNS WHERE TABLE_NAME = '\(obj.name)' ORDER BY COLUMN_ID;"
                state.runQuery()
            }
            Button("Số bản ghi (COUNT)") {
                state.queryText = "SELECT COUNT(*) AS TOTAL FROM \(obj.name);"; state.runQuery()
            }
        } else if isCodeObject(obj) {
            if t == "PACKAGE" {
                Button("Xem Spec + Body") { state.loadObjectSource(obj) }
                Button("Chỉ xem Spec") {
                    state.loadObjectSource(DBSchemaObject(id: obj.id + "-spec", name: obj.name, type: "PACKAGE SPEC"))
                }
                Button("Chỉ xem Body") {
                    state.loadObjectSource(DBSchemaObject(id: obj.id + "-body", name: obj.name, type: "PACKAGE BODY"))
                }
                Button("Run procedure trong package…") { runPackage(obj) }
            } else {
                Button("Xem source") { state.loadObjectSource(obj) }
                if t == "PROCEDURE" || t == "FUNCTION" {
                    Button("Run với tham số…") { runProcedure(obj) }
                }
            }
        }
        Divider()
        Button("Copy tên") {
            #if canImport(AppKit)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(obj.name, forType: .string)
            #endif
        }
    }

    /// Click object → sinh SQL phù hợp (xem dữ liệu / xem source — như SQL Developer).
    private func defaultQuery(for obj: DBSchemaObject) -> String {
        let isOracle = state.selectedProfile?.type == .oracle
        switch obj.type.uppercased() {
        case "TABLE", "VIEW", "MATERIALIZED VIEW":
            return isOracle
                ? "SELECT * FROM \(obj.name) WHERE ROWNUM <= 100;"
                : "SELECT * FROM \(obj.name) LIMIT 100;"
        case "PACKAGE", "PACKAGE BODY", "PROCEDURE", "FUNCTION", "TRIGGER", "TYPE":
            // Xem source code từ ALL_SOURCE
            return """
                SELECT LINE, TEXT FROM ALL_SOURCE \
                WHERE NAME = '\(obj.name)' AND TYPE = '\(obj.type.uppercased())' \
                ORDER BY LINE;
                """
        case "SEQUENCE":
            return "SELECT * FROM ALL_SEQUENCES WHERE SEQUENCE_NAME = '\(obj.name)';"
        default:
            return "-- \(obj.type): \(obj.name)"
        }
    }
}

// MARK: - Result table (cột thẳng hàng + lazy scroll, không phân trang)

struct ResultTableView: View {
    let result: DBResultSet
    let columns: [String]           // cột hiển thị (đã ẩn ROWID)
    @Binding var selectedRow: Int?
    /// Số dòng đang hiển thị — tăng dần khi scroll tới cuối (infinite scroll).
    @State private var visibleCount = 200
    private let step = 200
    private let colWidth: CGFloat = 160

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(Array(result.rows.prefix(visibleCount).enumerated()), id: \.offset) { idx, row in
                        rowView(row, index: idx)
                            .onAppear {
                                if idx == visibleCount - 1, visibleCount < result.rows.count {
                                    visibleCount = min(visibleCount + step, result.rows.count)
                                }
                            }
                    }
                } header: {
                    headerRow
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            ForEach(columns, id: \.self) { col in
                Text(col)
                    .font(.caption.bold())
                    .lineLimit(1)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .frame(width: colWidth, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .overlay(Rectangle().frame(width: 1).foregroundStyle(.quaternary), alignment: .trailing)
            }
        }
        .background(Color.accentColor.opacity(0.18))
    }

    private func rowView(_ row: DBRow, index: Int) -> some View {
        let isSelected = selectedRow == index
        return HStack(spacing: 0) {
            ForEach(columns, id: \.self) { col in
                Text(row[col].flatMap { $0 } ?? "NULL")
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .frame(width: colWidth, alignment: .leading)
                    .overlay(Rectangle().frame(width: 1).foregroundStyle(.quaternary.opacity(0.5)), alignment: .trailing)
            }
        }
        .background(isSelected ? Color.accentColor.opacity(0.30)
                    : (index % 2 == 0 ? Color.clear : Color.secondary.opacity(0.06)))
        .contentShape(Rectangle())
        .onTapGesture { selectedRow = (selectedRow == index) ? nil : index }
    }
}

// MARK: - Row editor (#3: thêm/sửa dòng)

struct RowEditorSheet: View {
    let columns: [String]
    let initial: [String: String]
    let isInsert: Bool
    let onSave: ([String: String]) -> Void
    let onCancel: () -> Void

    @State private var values: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isInsert ? "Thêm dòng mới" : "Sửa dòng").font(.title3.bold()).padding(16)
            Divider()
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(columns, id: \.self) { col in
                        HStack(alignment: .firstTextBaseline) {
                            Text(col).font(.caption.monospaced())
                                .frame(width: 150, alignment: .trailing).foregroundStyle(.secondary)
                            TextField("NULL", text: Binding(
                                get: { values[col] ?? "" },
                                set: { values[col] = $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                        }
                    }
                }.padding(16)
            }
            Divider()
            HStack {
                Text("Để trống = NULL").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Hủy", action: onCancel)
                Button(isInsert ? "Thêm" : "Lưu") { onSave(values) }
                    .buttonStyle(.borderedProminent)
            }.padding(16)
        }
        .onAppear {
            // Prefill mọi cột (đảm bảo INSERT có đủ danh sách cột).
            values = Dictionary(uniqueKeysWithValues: columns.map { ($0, initial[$0] ?? "") })
            activateSheet()
        }
    }
}

// MARK: - Chọn procedure trong package (#2)

struct PackageMemberSheet: View {
    let packageName: String
    let members: [String]
    let onPick: (String) -> Void
    let onCancel: () -> Void

    @State private var selected: String?
    @State private var search = ""

    private var filtered: [String] {
        search.isEmpty ? members : members.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Chọn procedure/function").font(.title3.bold()).padding(16)
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Tìm…", text: $search).textFieldStyle(.plain)
            }.padding(.horizontal, 16).padding(.bottom, 8)
            Divider()
            List(filtered, id: \.self, selection: $selected) { m in
                Label(m, systemImage: "gearshape").tag(m)
                    .onTapGesture { selected = m }
            }
            Divider()
            HStack {
                Spacer()
                Button("Hủy", action: onCancel)
                Button("Chọn") { if let s = selected { onPick(s) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected == nil)
            }.padding(16)
        }
        .onAppear { activateSheet() }
    }
}

// MARK: - Procedure/Function run sheet (#2)

struct ProcRunSheet: View {
    let objectName: String
    let isFunction: Bool
    let inArgs: [ProcArg]
    let onRun: ([String: String]) -> Void
    let onCancel: () -> Void

    @State private var values: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(isFunction ? "Function" : "Procedure"): \(objectName)")
                .font(.title3.bold()).padding(16)
            Divider()
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(inArgs) { arg in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(arg.name).font(.callout.monospaced())
                                Text("\(arg.inOut) · \(arg.dataType)").font(.caption2).foregroundStyle(.tertiary)
                            }
                            .frame(width: 170, alignment: .trailing)
                            TextField("NULL", text: Binding(
                                get: { values[arg.name] ?? "" },
                                set: { values[arg.name] = $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                        }
                    }
                }.padding(16)
            }
            Divider()
            HStack {
                Text("Để trống = NULL · DATE dạng YYYY-MM-DD HH24:MI:SS").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Hủy", action: onCancel)
                Button("Run") { onRun(values) }.buttonStyle(.borderedProminent)
            }.padding(16)
        }
        .onAppear { activateSheet() }
    }
}

// MARK: - Add Profile Sheet

struct AddProfileSheet: View {
    let onSave: (ConnectionProfile, String) -> Void
    let onCancel: () -> Void

    @State private var profile = ConnectionProfile()
    @State private var password = ""
    @State private var portText = "3306"

    // Focus management — cần thiết để sheet nhận keyboard input trên macOS
    private enum Field: Hashable { case name, host, port, database, username, password }
    @FocusState private var focus: Field?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Thêm connection").font(.title2.bold())
            fields
            Divider()
            HStack {
                Spacer()
                Button("Hủy", action: onCancel)
                Button("Lưu") { onSave(profile, password) }
                    .buttonStyle(.borderedProminent)
                    .disabled(profile.host.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear {
            portText = String(profile.port)
            activateSheet { focus = .name }
        }
    }

    private var fields: some View {
        VStack(spacing: 10) {
            dbRow("Tên hiển thị") {
                TextField("vd: Production MySQL", text: $profile.name)
                    .focused($focus, equals: .name)
                    .onSubmit { focus = .host }
            }
            dbRow("Loại DB") {
                Picker("", selection: $profile.type) {
                    ForEach(DatabaseType.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .onChange(of: profile.type) { _, t in
                    profile.port = t.defaultPort
                    portText = String(t.defaultPort)
                }
            }
            dbRow("Host") {
                TextField("localhost hoặc IP", text: $profile.host)
                    .focused($focus, equals: .host)
                    .onSubmit { focus = .port }
            }
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("Port")
                    .foregroundStyle(.secondary)
                    .frame(width: 120, alignment: .trailing)
                    .padding(.trailing, 12)
                TextField("", text: $portText)
                    .frame(width: 64)
                    .focused($focus, equals: .port)
                    .onSubmit { focus = .database }
                    .onChange(of: portText) { _, v in
                        let clean = v.filter(\.isNumber)
                        if clean != v { portText = clean }
                        if let p = Int(clean) { profile.port = p }
                    }
                Text("Database / Schema")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                TextField("schema hoặc db index", text: $profile.database)
                    .focused($focus, equals: .database)
                    .onSubmit { focus = profile.type == .redis ? .password : .username }
            }
            if profile.type != .redis {
                dbRow("Username") {
                    TextField("", text: $profile.username)
                        .focused($focus, equals: .username)
                        .onSubmit { focus = .password }
                }
                dbRow("Password") {
                    SecureField("", text: $password)
                        .focused($focus, equals: .password)
                        .onSubmit { if !profile.host.isEmpty { onSave(profile, password) } }
                }
            } else {
                dbRow("Auth password") {
                    SecureField("(để trống nếu không có)", text: $password)
                        .focused($focus, equals: .password)
                }
            }
        }
    }

    @ViewBuilder
    private func dbRow<C: View>(_ label: String, @ViewBuilder content: () -> C) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .trailing)
                .padding(.trailing, 12)
            content()
                .textFieldStyle(.roundedBorder)
        }
    }
}

struct ConnectPasswordSheet: View {
    let profile: ConnectionProfile
    let onConnect: (String) -> Void
    let onCancel: () -> Void
    @State private var password = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Kết nối \(profile.name.isEmpty ? profile.host : profile.name)").font(.title2.bold())
            SecureField("Password", text: $password)
                .focused($focused)
                .textFieldStyle(.roundedBorder)
                .onSubmit { onConnect(password) }
            HStack {
                Spacer()
                Button("Hủy", action: onCancel)
                Button("Kết nối") { onConnect(password) }.buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 340)
        .onAppear { activateSheet { focused = true } }
    }
}
