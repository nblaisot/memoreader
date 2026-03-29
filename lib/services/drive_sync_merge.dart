import '../models/book.dart';

/// Newest "alive" book record and newest deletion timestamp across local and
/// remote sources. Used by [bookShouldExistAfterMerge].
({Book? newestBook, DateTime? newestDeletion}) mergeBookAndDeletionTimestamps({
  required Book? localBook,
  required Book? remoteBook,
  required DateTime? localDeletion,
  required DateTime? remoteDeletion,
}) {
  Book? newestBook;
  if (localBook != null && remoteBook != null) {
    newestBook = remoteBook.dateAdded.isAfter(localBook.dateAdded)
        ? remoteBook
        : localBook;
  } else {
    newestBook = localBook ?? remoteBook;
  }

  DateTime? newestDeletion;
  if (localDeletion != null && remoteDeletion != null) {
    newestDeletion = localDeletion.isAfter(remoteDeletion)
        ? localDeletion
        : remoteDeletion;
  } else {
    newestDeletion = localDeletion ?? remoteDeletion;
  }

  return (newestBook: newestBook, newestDeletion: newestDeletion);
}

/// Whether the book should exist locally after merge (tombstone vs dateAdded).
bool bookShouldExistAfterMerge(Book? newestBook, DateTime? newestDeletion) {
  return newestBook != null &&
      (newestDeletion == null ||
          newestBook.dateAdded.isAfter(newestDeletion));
}
