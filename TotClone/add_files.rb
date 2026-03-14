require 'xcodeproj'
project_path = '/Users/martystev/VS/personal/NoteObs/TotClone/TotClone.xcodeproj'
project = Xcodeproj::Project.open(project_path)
target = project.targets.first

# Check to add to the main group 'TotClone'
group = project.main_group.children.find { |c| c.display_name == 'TotClone' || c.name == 'TotClone' }

files_to_add = [
    'Models.swift',
    'NotesViewModel.swift',
    'NotesFileStore.swift',
    'AppSettings.swift',
    'AppDelegate.swift',
    'Views.swift'
]

files_to_add.each do |filename|
    file_path = "/Users/martystev/VS/personal/NoteObs/TotClone/TotClone/#{filename}"
    file_ref = group.new_reference(file_path)
    target.add_file_references([file_ref])
    puts "Added #{filename}"
end

project.save
