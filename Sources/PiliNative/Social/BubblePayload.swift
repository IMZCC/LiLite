import Foundation

struct BubblePayload: Decodable {
  struct Base: Decodable {
    struct Tribe: Decodable { let title, summary: String? }
    let tribee_info: Tribe?
  }
  struct Categories: Decodable {
    struct Category: Decodable, Identifiable { let id: String, name: String? }
    let category_list: [Category]?
  }
  struct Sort: Decodable {
    struct Option: Decodable, Identifiable {
      let sort_type: Int, text: String?
      var id: Int { sort_type }
    }
    let show_sort: Bool?, sort_items: [Option]?, cur_sort_type: Int?
  }
  struct Content: Decodable {
    struct Row: Decodable, Identifiable {
      struct Meta: Decodable { let author, time_text, reply_count, view_stat: String? }
      let dyn_id: String, title: String?, meta: Meta?
      var id: String { dyn_id }
    }
    let count: String?, dyn_list: [Row]?
  }
  let base_info: Base?, category: Categories?, sort_info: Sort?, content: Content?
}
